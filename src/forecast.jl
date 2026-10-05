"""
What to assume. The defaults assume nothing: everyone pays on the due date and
a block stays a block.
"""
Base.@kwdef struct Scenario
    days::Int = 10              # business days to look ahead, the first included
    customerslate::Int = 0      # business days every customer pays after the due date
    customerslateupto::Int = 0  # a plan keeps the floor for every lateness from that to this
    releaseblocked::Bool = false
    floor::Int = 0              # minor units; a closing balance under it is flagged
    holdcode::String = "T"      # the payment block that is the schedule's own
    latecustomers::Int = -1     # how many customers may be late at once; -1 is all of them, together
end

"Every lateness a plan is held to: one, unless a range was asked for."
lateness(s::Scenario) = s.customerslate:max(s.customerslate, s.customerslateupto)

"The same scenario with every customer exactly `late` business days late."
assuming(s::Scenario, late::Int) =
    Scenario(s.days, late, late, s.releaseblocked, s.floor, s.holdcode, -1)

"Money expected to move: positive in, negative out."
struct Flow
    day::Date
    amount::Int
    source::Symbol              # :payable :receivable :payment :credit :return
    reference::String
    party::String
    note::String
end

"Money that is owed one way or the other and is not in the forecast, and why."
struct Aside
    reason::Symbol              # :blocked :overdue :rejected :currency :nodue :noinvoice :beyond
    amount::Int
    reference::String
    party::String
    note::String
end

struct DayLine
    day::Date
    opening::Int
    inflow::Int
    outflow::Int
    closing::Int
end

struct Forecast
    account::String
    currency::String
    now::DateTime
    pastcutoff::Bool
    position::Int
    scenario::Scenario
    days::Vector{DayLine}
    flows::Vector{Flow}
    asides::Vector{Aside}
end

"""
The day a payment run pays an item due on `due`: the due date or today,
whichever is later, moved to a business day - and to the next one when today's
cutoff has passed, because that file settles tomorrow.
"""
function runday(snap::Snapshot, due::Date)::Date
    day = onorafter(snap.calendar, max(due, snap.today))
    day == snap.today && snap.pastcutoff ? addbusinessdays(snap.calendar, day, 1) : day
end

squeeze(text) = replace(text, r"\s+" => "")

"""
The newest payment at the bank that is this item's: it decides what the item
is. The bank knows a payment by its `EndToEndId`, which is the supplier's
invoice number, and two suppliers may use the same number, or one use it
twice. So the reference alone is not enough: the payment is also for this
amount in this currency, and was not at the bank before the item was posted.
"""
function paymentfor(snap::Snapshot, item::OpenItem)
    item.reference == "" && return nothing
    index = findfirst(snap.payments) do p
        p.reference == item.reference && p.amount == item.amount && p.currency == item.currency &&
            (p.received === nothing || item.posted === nothing || p.received >= item.posted)
    end
    index === nothing ? nothing : snap.payments[index]
end

"The bank has it and has not sent it back: in the balance already, or on its way out."
atbank(payment) = payment !== nothing && payment.status == "accepted" && !payment.returned

"""
    forecast(snapshot, scenario = Scenario())

The closing balance of each of the next business days, and every movement
behind it. A pure function of the snapshot.

What it holds to, each of which is a way a cash forecast is quietly wrong:

- **A payment at the bank is not owed twice.** SAP keeps an item open until a
  statement clears it, so an accepted payment and its open item are one
  outflow, joined on the `EndToEndId`, the amount, and the payment not being
  older than the item: an invoice number used again is another invoice.
- **A blocked item is not money going out,** and an overdue receivable is not
  money coming in: it was due once already. Both are listed, not forecast.
- **The schedule's own block is not anyone else's.** An item it is holding is
  money going out on the day the schedule would let it go.
- **A payment the bank refused will be refused again.** Its item stays open in
  SAP and every run reselects it; it is listed with the bank's reason.
- **A payment that will come back comes back, and is owed again:** the credit
  on the day of the return, and the payment once more on the next run.
- **A credit the bank already holds replaces the receivable it names,** when
  it names one; a payer who quotes nothing is counted beside it.
"""
function forecast(snap::Snapshot, scenario::Scenario = Scenario())::Forecast
    # An item under the schedule's own block is paid when the schedule lets it
    # go, and that is decided again each morning from what is then true.
    any(i -> held(i, scenario), snap.items) && return planpayments(snap, scenario).forecast
    first(project(snap, scenario, Dict{String,Date}()))
end

"Blocked by the schedule, which will lift it, and not by somebody with a reason."
held(item::OpenItem, scenario::Scenario) =
    item.kind == :payable && item.block != "" && item.block == scenario.holdcode

"""
The forecast with some payables paid on a planned day instead of the day a run
would pay them: `planned` is keyed by `OpenItem.document`. Also returns the
payables a run would pay, each with the day it would - the ones a schedule may
move. `own` gives a customer a lateness of their own, in place of the
scenario's.
"""
function project(snap::Snapshot, scenario::Scenario, planned::Dict{String,Date},
                 own::Dict{String,Int} = Dict{String,Int}())
    cal = snap.calendar
    payables = Tuple{OpenItem,Date}[]
    flows, asides = Flow[], Aside[]
    ours(currency) = currency == snap.currency


    for p in snap.payments
        (p.status == "accepted" && ours(p.currency)) || continue
        if !p.booked
            day = onorafter(cal, max(something(p.settles, snap.today), snap.today))
            push!(flows, Flow(day, -p.amount, :payment, p.reference, "", "accepted, not yet settled"))
        elseif p.returndue !== nothing && !p.returned
            back = onorafter(cal, max(p.returndue, snap.today))
            push!(flows, Flow(back, p.amount, :return, p.reference, "", "a settled payment coming back"))
            push!(flows, Flow(addbusinessdays(cal, back, 1), -p.amount, :payable, p.reference, "",
                              "owed again after the return"))
        end
    end

    for c in snap.credits
        (!c.booked && ours(c.currency)) || continue
        push!(flows, Flow(onorafter(cal, max(c.books, snap.today)), c.amount, :credit,
                          "", c.payer, first(c.text, 60)))
    end
    quoted = squeeze(join((c.text for c in snap.credits), " "))

    for item in snap.items
        amount = item.kind == :payable ? -item.amount : item.amount
        aside(reason, note) = push!(asides, Aside(reason, amount, shown(item), item.party, note))
        if !ours(item.currency)
            aside(:currency, "in $(item.currency), and the account is in $(snap.currency)")
        elseif item.kind == :payable
            payment = paymentfor(snap, item)
            if item.reference == ""
                aside(:noinvoice, "no supplier invoice behind it, so no payment run selects it")
            elseif item.block != "" && !held(item, scenario) && !scenario.releaseblocked
                aside(:blocked, "payment block $(item.block)")
            elseif atbank(payment)
                continue    # at the bank already: in the balance, or a flow above
            elseif payment !== nothing && payment.status != "accepted"
                aside(:rejected, "the bank refused it" * (payment.reason == "" ? "" : ": $(payment.reason)"))
            elseif item.due === nothing
                aside(:nodue, "no due date")
            else
                day = runday(snap, item.due)
                push!(payables, (item, day))
                later = get(planned, item.document, day)
                push!(flows, Flow(later, amount, :payable, item.reference, item.party,
                                  later != day ? "held from $day" :
                                  item.reopened ? "returned once, owed again" :
                                  held(item, scenario) ? "the schedule lets it go" :
                                  item.block != "" ? "block $(item.block) released" : ""))
            end
        else
            late = get(own, item.party, scenario.customerslate)
            if occursin(item.number, quoted)
                continue    # the bank holds a credit that names it
            elseif item.due === nothing
                aside(:nodue, "no due date")
            elseif addbusinessdays(cal, item.due, late) < snap.today
                # Not here by the day it was expected, even allowing for lateness.
                aside(:overdue, "due $(item.due)")
            else
                push!(flows, Flow(addbusinessdays(cal, item.due, late), amount,
                                  :receivable, item.number, item.party,
                                  late > 0 ? "due $(item.due), assumed late" : ""))
            end
        end
    end

    first_day = onorafter(cal, snap.today)
    days = [addbusinessdays(cal, first_day, n) for n in 0:max(scenario.days, 1)-1]
    for f in flows
        f.day > last(days) &&
            push!(asides, Aside(:beyond, f.amount, f.reference, f.party, "expected $(f.day)"))
    end
    filter!(f -> f.day <= last(days), flows)
    sort!(flows; by = f -> (f.day, f.amount > 0 ? 0 : 1, f.reference))

    lines, balance = DayLine[], snap.position
    for day in days
        todays = [f.amount for f in flows if f.day == day]
        inflow, outflow = sum(filter(>(0), todays); init = 0), sum(filter(<(0), todays); init = 0)
        push!(lines, DayLine(day, balance, inflow, outflow, balance + inflow + outflow))
        balance += inflow + outflow
    end
    Forecast(snap.account, snap.currency, snap.now, snap.pastcutoff, snap.position,
             scenario, lines, flows, asides), payables
end

shown(item::OpenItem) = item.kind == :payable && item.reference != "" ? item.reference : item.number

"The day with the lowest closing balance."
lowest(f::Forecast) = f.days[argmin([d.closing for d in f.days])]

"The first day that closes under the floor, or `nothing`."
function breach(f::Forecast)
    index = findfirst(d -> d.closing < f.scenario.floor, f.days)
    index === nothing ? nothing : f.days[index]
end
