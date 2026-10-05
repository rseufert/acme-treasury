const DAY = dateformat"e dd u"

function report(io::IO, f::Forecast; plot::Bool = false)
    when = Dates.format(f.now, dateformat"yyyy-mm-dd HH:MM")
    println(io, f.account, "  ", f.currency, "  as of ", when,
            f.pastcutoff ? ", after the cutoff" : ", before the cutoff")
    println(io, "Booked balance now ", lpad(money(f.position), 16))
    println(io)
    println(io, rpad("day", 11), lpad("opening", 16), lpad("in", 16), lpad("out", 16), lpad("closing", 16))
    for d in f.days
        println(io, rpad(Dates.format(d.day, DAY), 11), lpad(money(d.opening), 16),
                lpad(money(d.inflow), 16), lpad(money(d.outflow), 16), lpad(money(d.closing), 16),
                d.closing < f.scenario.floor ? "  <" : "")
    end
    println(io)
    low, short = lowest(f), breach(f)
    println(io, "Lowest: ", money(low.closing), " on ", Dates.format(low.day, DAY))
    println(io, short === nothing ?
            "Never under the floor of $(money(f.scenario.floor))" :
            "Under the floor of $(money(f.scenario.floor)) from $(Dates.format(short.day, DAY))")
    if plot
        println(io)
        closings = [d.closing / 100 for d in f.days]
        show(io, stairs(collect(1:length(f.days)), closings;
                        style = :post, xlabel = "business day", ylabel = f.currency,
                        ylim = (min(minimum(closings), 0), max(maximum(closings), 1)),
                        width = 50, height = 10))
        println(io)
    end
    if !isempty(f.flows)
        println(io, "\nWhat moves it")
        for x in f.flows
            println(io, rstrip(string("  ", rpad(Dates.format(x.day, DAY), 11), lpad(money(x.amount), 16), "  ",
                                      rpad(x.source, 12), rpad(x.reference, 18), rpad(x.party, 14), x.note)))
        end
    end
    if !isempty(f.asides)
        println(io, "\nLeft out")
        for x in f.asides
            println(io, rstrip(string("  ", rpad(x.reason, 11), lpad(money(x.amount), 16), "  ",
                                      rpad(x.reference, 18), rpad(x.party, 14), x.note)))
        end
    end
end

function asjson(f::Forecast)
    low, short = lowest(f), breach(f)
    JSON.json(Dict(
        "account" => f.account, "currency" => f.currency, "asOf" => string(f.now),
        "pastCutoff" => f.pastcutoff, "position" => f.position, "floor" => f.scenario.floor,
        "lowest" => Dict("day" => string(low.day), "closing" => low.closing),
        "underFloorFrom" => short === nothing ? nothing : string(short.day),
        "days" => [Dict("day" => string(d.day), "opening" => d.opening, "in" => d.inflow,
                        "out" => d.outflow, "closing" => d.closing) for d in f.days],
        "flows" => [Dict("day" => string(x.day), "amount" => x.amount, "source" => string(x.source),
                         "reference" => x.reference, "party" => x.party, "note" => x.note)
                    for x in f.flows],
        "leftOut" => [Dict("reason" => string(x.reason), "amount" => x.amount,
                           "reference" => x.reference, "party" => x.party, "note" => x.note)
                      for x in f.asides]), 2)
end

const OUTCOME = Dict(
    (:block, :wanted) => "to block", (:block, :already) => "already blocked",
    (:block, :done) => "blocked", (:release, :wanted) => "to release",
    (:release, :done) => "released")

function report(io::IO, plan::Plan, wanted::Vector{Change}; applied::Bool = false,
                trusting = nothing, together = nothing)
    f, was = plan.forecast, plan.before
    floor = money(f.scenario.floor)
    when = Dates.format(f.now, dateformat"yyyy-mm-dd HH:MM")
    println(io, f.account, "  ", f.currency, "  as of ", when,
            f.pastcutoff ? ", after the cutoff" : ", before the cutoff")
    println(io, "A floor of ", floor, " over ", length(f.days), " business days")
    span, some = lateness(plan.scenario), plan.scenario.latecustomers
    length(span) > 1 &&
        println(io, some < 0 ? "Customers" : some == 1 ? "Any 1 customer" : "Any $some customers",
                " anywhere from ", first(span), " to ", last(span), " business days late")
    println(io)
    low, waslow, short = lowest(f), lowest(was), shortfall(plan)
    day(d) = Dates.format(d, DAY)
    if isempty(plan.holds)
        println(io, breach(was) === nothing ? "Nothing to hold: never under the floor" :
                    "Nothing to hold that would help")
    else
        println(io, "Hold")
        for h in plan.holds
            println(io, "  ", rpad(h.reference, 18), rpad(h.party, 14), lpad(money(h.amount), 16),
                    "  due ", day(h.due), ", from ", day(h.from), " to ", day(h.to),
                    ", ", h.days, h.days == 1 ? " day" : " days")
        end
    end
    println(io)
    println(io, "Lowest: ", money(low.closing), " on ", day(low.day),
            isempty(plan.holds) ? "" : ", where it was $(money(waslow.closing)) on $(day(waslow.day))")
    if length(span) > 1
        worst = worstcase(plan)
        days(n) = n == 1 ? "1 day late" : "$n days late"
        who = some < 0 ? "customers " * days(worst.scenario.customerslate) :
              isempty(plan.late) ? "nobody late" :
              join(("$customer $(days(plan.late[customer]))" for customer in sort!(collect(keys(plan.late)))), " and ")
        println(io, "At worst: ", money(lowest(worst).closing), " on ", day(lowest(worst).day), ", with ", who)
    end
    short === nothing || println(io, "No plan keeps the floor: ", money(f.scenario.floor - short.closing),
                                 " short on ", day(short.day))
    if trusting !== nothing
        more = helddays(plan) - helddays(trusting)
        println(io, "The caution costs ", more, more == 1 ? " invoice-day" : " invoice-days",
                " more than trusting the due dates",
                together === nothing ? "" :
                ", and $(helddays(together) - helddays(plan)) fewer than every customer late")
    end
    if !isempty(wanted)
        println(io, "\nIn SAP", applied ? "" : " (nothing was changed: --apply does it)")
        for c in wanted
            said = c.outcome == :refused ? "refused: $(c.message)" : OUTCOME[(c.action, c.outcome)]
            println(io, "  ", rpad(c.reference, 18), rpad(c.party, 14), lpad(money(c.amount), 16), "  ", said,
                    c.until === nothing || c.outcome == :refused ? "" : " until $(day(c.until))")
        end
    end
end

function asjson(plan::Plan, wanted::Vector{Change}; applied::Bool = false,
                trusting = nothing, together = nothing)
    f, short, worst = plan.forecast, shortfall(plan), worstcase(plan)
    low, waslow = lowest(f), lowest(plan.before)
    JSON.json(Dict(
        "account" => f.account, "currency" => f.currency, "asOf" => string(f.now),
        "floor" => f.scenario.floor, "applied" => applied,
        "holds" => [Dict("reference" => h.reference, "party" => h.party, "amount" => h.amount,
                         "due" => string(h.due), "from" => string(h.from), "to" => string(h.to),
                         "days" => h.days) for h in plan.holds],
        "lowest" => Dict("day" => string(low.day), "closing" => low.closing),
        "lowestBefore" => Dict("day" => string(waslow.day), "closing" => waslow.closing),
        "customersLate" => collect(lateness(plan.scenario)),
        "lateCustomers" => plan.scenario.latecustomers < 0 ? nothing : plan.scenario.latecustomers,
        "worst" => Dict("customersLate" => plan.scenario.latecustomers < 0 ?
                                           worst.scenario.customerslate : plan.late,
                        "day" => string(lowest(worst).day), "closing" => lowest(worst).closing),
        # The forecast under the plan in each case it was held to, the first the one above.
        "cases" => [Dict("customersLate" => plan.scenario.latecustomers >= 0 && n == 2 ? plan.late :
                                            c.scenario.customerslate,
                         "days" => [Dict("day" => string(d.day), "closing" => d.closing) for d in c.days])
                    for (n, c) in enumerate(plan.cases)],
        "heldDays" => helddays(plan),
        "heldDaysTrusting" => trusting === nothing ? nothing : helddays(trusting),
        "heldDaysAllLate" => together === nothing ? nothing : helddays(together),
        "shortfall" => short === nothing ? nothing :
                       Dict("day" => string(short.day), "amount" => f.scenario.floor - short.closing),
        "days" => [Dict("day" => string(d.day), "opening" => d.opening, "in" => d.inflow,
                        "out" => d.outflow, "closing" => d.closing) for d in f.days],
        "changes" => [Dict("action" => string(c.action), "invoice" => c.invoice,
                           "reference" => c.reference, "party" => c.party, "amount" => c.amount,
                           "until" => c.until === nothing ? nothing : string(c.until),
                           "outcome" => string(c.outcome), "message" => c.message)
                      for c in wanted]), 2)
end
