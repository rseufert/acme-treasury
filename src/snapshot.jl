# What the forecast is made from. Reading it is the only part that touches the
# network; `forecast` is a pure function of a Snapshot, so it can be tested
# without either mock.

"An open line in SAP: `kind` is `:payable` (K) or `:receivable` (D)."
Base.@kwdef struct OpenItem
    kind::Symbol
    document::String            # CompanyCode/FiscalYear/AccountingDocument
    number::String              # AccountingDocument alone, what a payer might quote
    party::String
    amount::Int                 # minor units, never negative
    currency::String
    due::Union{Date,Nothing}
    block::String = ""
    reference::String = ""      # the supplier's invoice number, a payment's EndToEndId
    reopened::Bool = false      # ClearingIsReversed: paid once, and it came back
    invoice::String = ""        # SupplierInvoice/FiscalYear, where a payment block is set
end

"A payment the bank has decided on, from the paying account."
Base.@kwdef struct BankPayment
    reference::String           # EndToEndId
    amount::Int
    currency::String
    status::String              # accepted, rejected
    reason::String = ""
    settles::Union{Date,Nothing} = nothing
    booked::Bool = false
    returndue::Union{Date,Nothing} = nothing
    returned::Bool = false
end

"Money on its way in that the bank already knows about."
Base.@kwdef struct BankCredit
    amount::Int
    currency::String
    books::Date
    booked::Bool = false
    payer::String = ""
    text::String = ""           # the structured reference and the note, joined
end

Base.@kwdef struct Snapshot
    account::String
    currency::String
    now::DateTime
    today::Date
    pastcutoff::Bool
    calendar::BankCalendar = BankCalendar()
    position::Int               # the booked balance now, minor units
    items::Vector{OpenItem} = OpenItem[]
    payments::Vector{BankPayment} = BankPayment[]
    credits::Vector{BankCredit} = BankCredit[]
end
