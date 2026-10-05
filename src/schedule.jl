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
forecast with nothing held.
"""
struct Plan
    holds::Vector{Hold}
    before::Forecast
    forecast::Forecast
end

"""
The worst day the plan still leaves under the floor, or `nothing`. When it is
a day, no timing of payments keeps the floor: the answer is money.
"""
function shortfall(plan::Plan)
    day = lowest(plan.forecast)
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

The solver chooses the days; the plan's forecast is then made again by
`forecast`'s own arithmetic, in whole minor units, and checked.
"""
function planpayments(snap::Snapshot, scenario::Scenario = Scenario())::Plan
    before, payables = project(snap, scenario, Dict{String,Date}())
    breach(before) === nothing && return Plan(Hold[], before, before)
    days = [d.day for d in before.days]
    movable = [(item, findfirst(==(day), days)) for (item, day) in payables if day <= last(days)]
    isempty(movable) && return Plan(Hold[], before, before)

    # With everything held to the last day, every day closes as high as any
    # plan can make it: that, or the floor, is what each day is held to.
    document(pair) = first(pair).document
    best, _ = project(snap, scenario, Dict(document(m) => last(days) for m in movable))
    least = [min(scenario.floor, d.closing) for d in best.days]

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
    unpaid = [best.days[t].closing + (t == T ? sum(amount) : 0) for t in 1:T]
    @constraint(model, [t = 1:T],
                sum(amount[i] * pays[i, s] for i in 1:n for s in start[i]:t; init = 0) <=
                unpaid[t] - least[t])
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

    after, _ = project(snap, scenario, Dict(document(movable[i]) => days[chosen[i]] for i in 1:n))
    all(d.closing >= floor for (d, floor) in zip(after.days, least)) ||
        error("the solver's plan does not keep the floor it was held to")
    holds = [Hold(item.document, item.reference, item.party, item.amount, item.due,
                  days[start[i]], days[chosen[i]], chosen[i] - start[i])
             for (i, (item, _)) in enumerate(movable) if chosen[i] > start[i]]
    Plan(sort!(holds; by = h -> (h.to, h.from, h.reference)), before, after)
end
