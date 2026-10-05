"An invoice the plan pays later than a run would."
struct Hold
    document::String
    reference::String
    party::String
    amount::Int
    due::Date
    from::Date                  # the day a run would pay it
    to::Date                    # the day the plan pays it
    days::Int                   # business days between the two
end

"""
What to hold, and the forecast that follows from holding it. `before` is the
forecast with nothing held. Both are for the lateness that was asked for;
`cases` is the forecast under the plan for every lateness it was held to, the
first of them `forecast` itself. When only some customers may be late there
are too many cases to list, and `cases` is two: `forecast`, and the worst of
them, in which the customers in `late` are the late ones.
"""
struct Plan
    holds::Vector{Hold}
    before::Forecast
    forecast::Forecast
    cases::Vector{Forecast}
    late::Dict{String,Int}      # with `latecustomers`: who is late in the worst case, and by how long
end

"The case the plan leaves lowest: the lateness that would hurt most, and of equals the latest."
worstcase(plan::Plan) =
    plan.cases[findlast(==(minimum(lowest(f).closing for f in plan.cases)), [lowest(f).closing for f in plan.cases])]

"Invoice-days held: what a plan costs in lateness, without the amounts."
helddays(plan::Plan) = sum(h.days for h in plan.holds; init = 0)

"""
The worst day the plan still leaves under the floor, or `nothing`. When it is
a day, no timing of payments keeps the floor: the answer is money.
"""
function shortfall(plan::Plan)
    day = lowest(worstcase(plan))
    day.closing < plan.forecast.scenario.floor ? day : nothing
end

"""
    planpayments(snapshot, scenario = Scenario())

Which payables to hold, and until which business day, so that no day closes
under `scenario.floor`. A pure function of the snapshot, as `forecast` is.

What it holds to:

- **Nothing is held when nothing is wrong.** A forecast that keeps the floor
  gives an empty plan, and the solver is not called.
- **It only moves what a run would pay,** and only later, to a business day
  inside the horizon. Blocked and refused items, other currencies and payments
  already at the bank are not its to move.
- **The least lateness.** Of the plans that keep the floor, the one with the
  smallest sum of amount times business days held: a large invoice is not held
  where a small one would do, and nothing longer than it must be.
- **A floor no plan can keep is not an error.** Holding everything to the last
  day gives every earlier day the best closing it can have, so a day that is
  still under the floor then is held to that closing instead, and
  `shortfall` names the worst of them.
- **The same snapshot gives the same plan.** Among plans of equal lateness,
  the invoice due latest is held longest, then the next, and invoices due the
  same day go by reference.
- **Customers may be late.** With `customerslateupto`, the one plan keeps the
  floor whether every customer pays `customerslate` business days late, or
  any number up to that. The holds are the same in every case, because a
  block is set before anyone knows which is true.
- **Or only some of them.** With `latecustomers` as well, each customer is
  late on their own, and at most that many at once: the floor is kept
  whichever they are. A customer with a receivable already past due and still
  expected is late for certain, and is not one of the number.

The solver chooses the days; the plan's forecast is then made again by
`forecast`'s own arithmetic, in whole minor units, and checked.
"""
function planpayments(snap::Snapshot, scenario::Scenario = Scenario())::Plan
    # One case for each lateness. What a run would pay is the same in all.
    cases = [assuming(scenario, late) for late in lateness(scenario)]
    made(planned) = [first(project(snap, case, planned)) for case in cases]
    nothing_held = Dict{String,Date}()
    before, payables = project(snap, first(cases), nothing_held)
    days = [d.day for d in before.days]

    # What each day closes at under a plan, in everything the plan is held to:
    # a row for each lateness, or, when only some customers may be late, one
    # row that is each day's own worst case.
    some = scenario.latecustomers >= 0 && length(cases) > 1
    short, who = some ? exposure(snap, scenario, days) : (Int[], Dict{String,Int}[])
    closings(planned) = some ?
        [[d.closing for d in first(project(snap, first(cases), planned)).days] .- short] :
        [[d.closing for d in f.days] for f in made(planned)]
    function plan(holds, planned)
        some || return Plan(holds, before, first(made(planned)), made(planned), Dict{String,Int}())
        after = first(project(snap, first(cases), planned))
        day = argmin(only(closings(planned)))
        worst = first(project(snap, first(cases), planned, who[day]))
        worst.days[day].closing == only(closings(planned))[day] ||
            error("the worst case does not add up to what the plan was held to")
        Plan(holds, before, after, [after, worst], who[day])
    end

    all(>=(scenario.floor), Iterators.flatten(closings(nothing_held))) && return plan(Hold[], nothing_held)
    movable = [(item, findfirst(==(day), days)) for (item, day) in payables if day <= last(days)]
    isempty(movable) && return plan(Hold[], nothing_held)

    # With everything held to the last day, every day closes as high as any
    # plan can make it: that, or the floor, is what each day is held to, row
    # by row.
    document(pair) = first(pair).document
    best = closings(Dict(document(m) => last(days) for m in movable))
    least = [min.(scenario.floor, row) for row in best]

    T, n = length(days), length(movable)
    amount = [item.amount for (item, _) in movable]
    start = [index for (_, index) in movable]
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    set_attribute(model, "threads", 1)
    set_attribute(model, "mip_rel_gap", 0.0)
    set_attribute(model, "mip_abs_gap", 0.0)
    @variable(model, pays[i = 1:n, t = start[i]:T], Bin)
    @constraint(model, [i = 1:n], sum(pays[i, t] for t in start[i]:T) == 1)
    # A day's closing is what it would be with no payable paid, less what has
    # been paid by then.
    unpaid = [[row[t] + (t == T ? sum(amount) : 0) for t in 1:T] for row in best]
    @constraint(model, [c = 1:length(best), t = 1:T],
                sum(amount[i] * pays[i, s] for i in 1:n for s in start[i]:t; init = 0) <=
                unpaid[c][t] - least[c][t])
    @expression(model, late[i = 1:n], sum((t - start[i]) * pays[i, t] for t in start[i]:T))
    @expression(model, cost, sum(amount[i] * late[i] for i in 1:n))

    # Solve, and read what is asked for before the model is changed again.
    function solve(read)
        optimize!(model)
        is_solved_and_feasible(model) || error("the schedule did not solve: $(termination_status(model))")
        read()
    end
    @objective(model, Min, cost)
    least_cost = solve(() -> round(Int, value(cost)))
    @constraint(model, cost <= least_cost + 0.5)
    # Equal lateness is settled one invoice at a time, the one due latest first.
    order = sortperm(movable; by = m -> (-Dates.value(first(m).due), first(m).reference, document(m)))
    chosen = copy(start)
    for i in order
        @objective(model, Max, late[i])
        held = solve(() -> round(Int, value(late[i])))
        @constraint(model, late[i] >= held - 0.5)
        chosen[i] += held
    end

    planned = Dict(document(movable[i]) => days[chosen[i]] for i in 1:n)
    all(all(row .>= floors) for (row, floors) in zip(closings(planned), least)) ||
        error("the solver's plan does not keep the floor it was held to")
    holds = [Hold(item.document, item.reference, item.party, item.amount, item.due,
                  days[start[i]], days[chosen[i]], chosen[i] - start[i])
             for (i, (item, _)) in enumerate(movable) if chosen[i] > start[i]]
    plan(sort!(holds; by = h -> (h.to, h.from, h.reference)), planned)
end

"""
What customers being late can take from each day, when at most
`scenario.latecustomers` of them are late at once: the amount missing from
each day's closing in that day's worst case, and who is late in it and by how
many business days.

It is worked out before any plan is, because it does not depend on one:
holding an invoice changes nothing a customer pays. For each customer and
each day, what would have come in by then and does not at the lateness that
is worst for that day; then the largest few of those. Each day has its own
worst set of customers, which is right: the floor has to hold for every set.

A customer with a receivable past its due date and still expected inside the
range is late for certain, and is counted in full beside the few.
"""
function exposure(snap::Snapshot, scenario::Scenario, days::Vector{Date})
    span = collect(lateness(scenario))
    # received[k][customer][t]: what has come in from them by day t, if they are span[k] late.
    received = map(span) do late
        byparty = Dict{String,Vector{Int}}()
        for f in first(project(snap, assuming(scenario, late), Dict{String,Date}())).flows
            f.source == :receivable || continue
            row = get!(() -> zeros(Int, length(days)), byparty, f.party)
            row[findfirst(==(f.day), days):end] .+= f.amount
        end
        byparty
    end
    customers = sort!(collect(union(keys.(received)...)))
    quoted = squeeze(join((c.text for c in snap.credits), " "))
    certain = Set(i.party for i in snap.items if i.kind == :receivable && i.due !== nothing &&
                  i.currency == snap.currency && !occursin(i.number, quoted) && i.due < snap.today &&
                  addbusinessdays(snap.calendar, i.due, last(span)) >= snap.today)
    at(k, customer, t) = get(received[k], customer, zeros(Int, length(days)))[t]
    short, who = zeros(Int, length(days)), [Dict{String,Int}() for _ in days]
    for t in eachindex(days)
        # (what is missing, the customer, the lateness that does it): the worst
        # lateness for this day, and of equals the longest.
        losses = map(customers) do customer
            had = [at(k, customer, t) for k in eachindex(span)]
            k = findlast(==(minimum(had)), had)
            (had[1] - had[k], customer, span[k])
        end
        sure = filter(l -> l[2] in certain, losses)
        rest = sort!(filter(l -> !(l[2] in certain), losses); by = l -> (-l[1], l[2]))
        for (loss, customer, late) in vcat(sure, first(rest, min(scenario.latecustomers, length(rest))))
            loss > 0 || continue
            short[t] += loss
            who[t][customer] = late
        end
    end
    short, who
end
