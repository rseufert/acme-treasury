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
