# Reading the two mocks. Both are spoken to over HTTP, as a real S/4HANA
# system and a real bank would be; nothing here imports either.

const ODATA = "/sap/opu/odata/sap"
const ITEMS = ODATA * "/API_OPLACCTGDOCITEMCUBE_SRV/A_OperationalAcctgDocItemCube"
const INVOICES = ODATA * "/API_SUPPLIERINVOICE_PROCESS_SRV/A_SupplierInvoice"

"A side that did not answer, or answered with something that cannot be used."
struct Unusable <: Exception
    message::String
end
Base.showerror(io::IO, e::Unusable) = print(io, e.message)

function send(side::String, method::String, url::String, headers = [], body = "")
    try
        HTTP.request(method, url, headers, body; status_exception = false, retry = false,
                     connect_timeout = 5, request_timeout = 30)
    catch error
        error isa InterruptException && rethrow()
        throw(Unusable("$side did not answer at $url"))
    end
end

function call(side::String, method::String, url::String)
    response = send(side, method, url)
    response.status < 300 ||
        throw(Unusable("$side answered $(response.status) to $method $url"))
    String(response.body)
end

# -- SAP -----------------------------------------------------------------------

"`/Date(1791158400000)/` is 2026-10-05."
function sapdate(raw)::Union{Date,Nothing}
    raw isa AbstractString || return nothing
    m = match(r"^/Date\((-?\d+)\)/$", raw)
    m === nothing ? nothing : Date(unix2datetime(parse(Int, m[1]) / 1000))
end

function odata(base::String, path::String, filter::String = "")
    query = Dict("\$format" => "json")
    filter == "" || (query["\$filter"] = filter)
    url = string(base, path, "?", HTTP.escapeuri(query))
    rows = Any[]
    while true
        page = JSON.parse(call("SAP", "GET", url))["d"]
        append!(rows, page["results"])
        url = get(page, "__next", nothing)
        url === nothing && return rows
    end
end

"""
Every open supplier and customer line in SAP, each payable with the invoice
number its payment will carry. Blocked items are read too: the forecast lists
them, which a payment run's selection would not.
"""
function openitems(sap::String)::Vector{OpenItem}
    key(row) = (row["CompanyCode"], row["FiscalYear"], row["AccountingDocument"])
    invoices = Dict(key(row) => row for row in odata(sap, INVOICES))
    invoice(row, field) = haskey(invoices, key(row)) ? invoices[key(row)][field] : ""
    items = OpenItem[]
    for (letter, kind, party) in (("K", :payable, "Supplier"), ("D", :receivable, "Customer"))
        rows = odata(sap, ITEMS, "AccountingDocumentItemType eq '$letter' and " *
                                 "ClearingAccountingDocument eq ''")
        for row in rows
            push!(items, OpenItem(;
                kind,
                document = join(key(row), "/"),
                number = row["AccountingDocument"],
                party = row[party],
                amount = abs(cents(row["AmountInTransactionCurrency"])),
                currency = row["TransactionCurrency"],
                due = sapdate(row["NetDueDate"]),
                block = something(row["PaymentBlockingReason"], ""),
                reference = invoice(row, "SupplierInvoiceIDByInvcgParty"),
                reopened = row["ClearingIsReversed"] === true,
                invoice = kind == :payable && haskey(invoices, key(row)) ?
                          invoice(row, "SupplierInvoice") * "/" * invoice(row, "FiscalYear") : ""))
        end
    end
    items
end

"""
Writes to SAP: an `X-CSRF-Token` fetched once, with the session cookie HTTP.jl
keeps for it.
"""
mutable struct SapSession
    base::String
    token::String
end
SapSession(base::String) = SapSession(base, "")

"""
Set a supplier invoice's payment block, or lift it with `""`. SAP carries it
to the open item a payment run selects. Returns `""`, or why SAP refused.
"""
function setblock!(session::SapSession, invoice::String, code::String)::String
    if session.token == ""
        fetched = send("SAP", "GET", session.base * ODATA * "/API_SUPPLIERINVOICE_PROCESS_SRV/",
                       ["X-CSRF-Token" => "Fetch"])
        session.token = HTTP.header(fetched, "X-CSRF-Token", "")
    end
    number, year = split(invoice, "/")
    response = send("SAP", "PATCH",
                    "$(session.base)$INVOICES(SupplierInvoice='$number',FiscalYear='$year')",
                    ["Content-Type" => "application/json", "Accept" => "application/json",
                     "X-CSRF-Token" => session.token],
                    JSON.json(Dict("PaymentBlockingReason" => code)))
    response.status < 300 && return ""
    said = try
        JSON.parse(String(response.body))["error"]["message"]["value"]
    catch
        ""
    end
    "SAP answered $(response.status)" * (said == "" ? "" : ": $said")
end

# -- the bank --------------------------------------------------------------------

bankdate(raw) = raw === nothing ? nothing : Date(first(raw, 10))

struct BankClock
    now::DateTime
    today::Date
    pastcutoff::Bool
    calendar::BankCalendar
end

function bankclock(bank::String)::BankClock
    clock = JSON.parse(call("the bank", "GET", bank * "/_mock/state"))["clock"]
    BankClock(DateTime(first(clock["now"], 19)), Date(clock["date"]), clock["pastCutoff"],
              BankCalendar(Set(Date.(clock["holidays"]))))
end

"""
Every element called `name` under `node`, nearest first within each branch and
not looked for inside one another: the `Amt` of an entry, not of its details.
ISO 20022 puts every element in the message's namespace, so the local name is
what is compared.
"""
function named(node, name::String)
    found = []
    for child in eachelement(node)
        nodename(child) == name ? push!(found, child) : append!(found, named(child, name))
    end
    found
end

"""
The booked balance now, from an intraday `camt.052` asked for on the spot.

The report is checked before it is believed: opening balance plus the entries
must be the interim balance, to the cent.
"""
function position(bank::String, account::String)
    receipt = JSON.parse(call("the bank", "POST", "$bank/_mock/accounts/$account/report"))
    xml = call("the bank", "GET", "$bank/_mock/mailbox/$(receipt["message_id"])")
    report = root(parsexml(xml))
    # The first is the element's own: an entry's `CdtDbtInd` comes before the
    # one its transaction details repeat.
    text(name, node) = nodecontent(first(named(node, name)))
    signed(node) = (text("CdtDbtInd", node) == "DBIT" ? -1 : 1) *
                   cents(nodecontent(first(named(node, "Amt"))))
    balances = Dict(text("Cd", b) => b for b in named(report, "Bal"))
    haskey(balances, "OPBD") && haskey(balances, "ITBD") ||
        throw(Unusable("the bank's camt.052 for $account gives no opening and interim balance"))
    opening, interim = signed(balances["OPBD"]), signed(balances["ITBD"])
    entries = sum(signed(entry) for entry in named(report, "Ntry"); init = 0)
    opening + entries == interim || throw(Unusable(
        "the bank's camt.052 for $account does not add up: $(money(opening)) opening and " *
        "$(money(entries)) in entries is not $(money(interim))"))
    currency = first(named(balances["ITBD"], "Amt"))["Ccy"]
    (; balance = interim, currency)
end

function payments(bank::String, account::String)::Vector{BankPayment}
    rows = JSON.parse(call("the bank", "GET", bank * "/_mock/payments"))
    [BankPayment(;
        reference = row["end_to_end_id"],
        amount = row["amount"],
        currency = row["currency"],
        status = row["status"],
        reason = something(row["reason"], ""),
        settles = bankdate(row["settlement_date"]),
        booked = row["booked_at"] !== nothing,
        returndue = bankdate(row["return_due"]),
        returned = row["returned_at"] !== nothing)
     for row in rows if row["account_id"] == account]
end

function credits(bank::String, account::String)::Vector{BankCredit}
    rows = JSON.parse(call("the bank", "GET", bank * "/_mock/credits"))
    [BankCredit(;
        amount = row["amount"],
        currency = row["currency"],
        books = Date(row["booking_date"]),
        booked = row["booked_at"] !== nothing,
        payer = something(row["debtor_name"], ""),
        text = join(vcat(something(row["reference"], ""), row["note"]), " "))
     for row in rows if row["account_id"] == account]
end

"Everything the forecast is made from, read from both sides at once."
function snapshot(sap::String, bank::String, account::String)::Snapshot
    clock = bankclock(bank)
    booked = position(bank, account)
    Snapshot(; account, currency = booked.currency, now = clock.now, today = clock.today,
             pastcutoff = clock.pastcutoff, calendar = clock.calendar, position = booked.balance,
             items = openitems(sap), payments = payments(bank, account),
             credits = credits(bank, account))
end
