# Draw the third film from its capture: julia --project=film film/render_late.jl
#
# It reads film/late.json and nothing else. The capture is one week played
# twice, and the film is its two acts in order. In each, Monday's plan is
# drawn as a line: the case the plan itself calls its worst, which for a plan
# that trusts the due dates is the only case it has. Each statement is then a
# green block where it lands on the line, or a red one with the distance drawn
# where it does not, and the floor turns red when a statement is under it.
#
# Nothing here knows which act goes wrong. That is the capture's to say.

include(joinpath(@__DIR__, "look.jl"))

# -- the capture ---------------------------------------------------------------

const RUN = JSON.parsefile(joinpath(@__DIR__, "late.json"))
const FLOOR = RUN["floor"]
closings(days) = Dict(Date(d["day"]) => d["closing"] for d in days)

"One act: the statements, the line Monday's plan drew, and what it held."
function act(captured)
    closed = closings(captured["statements"])
    monday = captured["plans"][1]
    upto = captured["customersLateUpTo"]
    # The line is the case the plan names as its worst.
    worst = only(c for c in monday["cases"] if c["customersLate"] == monday["worst"]["customersLate"])
    (; closed, upto, planned = closings(worst["days"]),
     holds = [(reference = h["reference"], amount = h["amount"], from = Date(h["from"]),
               to = Date(h["to"]), days = h["days"]) for h in monday["holds"]],
     paid = Dict(i["reference"] => Date(r["day"]) for r in captured["runs"] for i in r["items"]
                 if i["status"] == "accepted"),
     dearer = monday["heldDaysTrusting"] === nothing ? nothing : monday["heldDays"] - monday["heldDaysTrusting"])
end
const ACTS = act.(RUN["acts"])
const DAYS = sort(collect(keys(first(ACTS).closed)))
const X = Dict(day => i for (i, day) in enumerate(DAYS))

"A forecast as the line it draws: flat across each day, at what the day closes at."
steps(closing) = [Point2f(X[day] + side, closing[day] / 100) for day in DAYS if haskey(closing, day)
                  for side in (-0.5, 0.5)]

# -- the story, one frame at a time ---------------------------------------------

Base.@kwdef mutable struct Frame
    clock::String = ""
    status::String = ""
    alarm::Bool = false                 # the status line in red
    act::Int = 1
    reach::Float64 = 0.0                # how far the plan's line is drawn
    moved::Float64 = 0.0                # each hold's mark, 0 to 1
    landed::Vector{Float64} = zeros(length(DAYS))       # each statement's block, 0 to 1
    missed::Vector{Bool} = falses(length(DAYS))
    under::Bool = false                 # a statement has closed under the floor
end

const FILM = Frame[]
now_ = Frame()
shoot() = push!(FILM, deepcopy(now_))
hold(seconds) = foreach(_ -> shoot(), 1:round(Int, seconds * FPS))
function type(text; alarm = false)
    now_.alarm = alarm
    for n in KEYS:KEYS:length(text) + KEYS - 1
        now_.status = first(text, n)
        shoot()
    end
end
function ease(field, to; seconds)
    for t in range(0, 1; length = round(Int, seconds * FPS))
        setfield!(now_, field, to * (1 - (1 - t)^3))
        shoot()
    end
end
morning(day) = stamp(day) * " 09:00"
whole(minor) = replace(money(minor)[1:end-3], "," => "")
across = length(DAYS) + 0.5
late(n) = n == 1 ? "1 DAY LATE" : "$n DAYS LATE"

for (number, a) in enumerate(ACTS)
    global now_ = Frame(; act = number, clock = morning(first(DAYS)))
    number == 1 ? hold(0.6) : (type("THE SAME WEEK, FROM THE SAME MONDAY"); hold(BEAT))
    type("> ACME-TREASURY PLAN --APPLY --FLOOR $(whole(FLOOR))" *
         (a.upto > 0 ? " --CUSTOMERS-LATE-UP-TO $(a.upto)" : ""))
    ease(:reach, across; seconds = 1.2)
    for h in a.holds
        type("HOLD $(h.reference) $(money(h.amount)) UNTIL $(stamp(h.to))")
        ease(:moved, 1.0; seconds = 0.4)
        hold(BEAT)
    end
    type(a.upto > 0 ? "THE LINE IS THE PLAN IF CUSTOMERS PAY $(late(a.upto))" :
                      "THE LINE IS THE PLAN IF CUSTOMERS PAY ON THE DAY")
    hold(WAIT)

    for today in DAYS
        for h in a.holds
            get(a.paid, h.reference, nothing) == today || continue
            now_.clock = morning(today)
            waited = X[today] - X[h.from]
            type("BLOCK LIFTED. $(h.reference) PAID $(stamp(today)), $(late(waited))")
            hold(BEAT)
        end
        said, closed = a.planned[today], a.closed[today]
        now_.clock = stamp(today) * " 23:59"
        now_.missed[X[today]] = said != closed
        for t in range(0, 1; length = 6)
            now_.landed[X[today]] = t
            shoot()
        end
        if closed < FLOOR
            now_.under = true
            type("CAMT.053 $(stamp(today)) CLOSES $(money(closed)). UNDER THE FLOOR"; alarm = true)
            hold(WAIT)
            type("THE PLAN SAID $(money(said)). OFF BY $(money(abs(closed - said)))"; alarm = true)
            hold(WAIT)
        elseif said != closed
            type("CAMT.053 $(stamp(today)) CLOSES $(money(closed)). OFF BY $(money(abs(closed - said)))"; alarm = true)
            hold(WAIT)
        else
            # A day that goes as planned is said at once, not typed: there are many.
            now_.alarm, now_.status = false, "CAMT.053 $(stamp(today)) CLOSES $(money(closed)). AS PLANNED"
            hold(0.5)
        end
    end

    under = count(day -> a.closed[day] < FLOOR, DAYS)
    now_.clock = morning(last(DAYS) + Day(1))
    cost = a.dearer === nothing ? "" :
           ". THE CAUTION COST $(a.dearer) INVOICE-DAY$(a.dearer == 1 ? "" : "S")"
    type("$(length(DAYS)) STATEMENTS. $(under == 0 ? "NONE" : under) UNDER THE FLOOR$cost"; alarm = under > 0)
    hold(number == length(ACTS) ? FINAL : WAIT)
end

# -- the picture ----------------------------------------------------------------

set_theme!(fonts = (; regular = FACE, bold = FACE))
fig = Figure(size = (800, 450), backgroundcolor = BACKGROUND, figure_padding = (18, 22, 10, 12))
shown = Observable(FILM[1])
tell(what) = lift(what, shown)

Label(fig[1, 1], "$(RUN["account"]) $(RUN["currency"])  CLOSING BALANCE"; color = MUTED,
      fontsize = 26, halign = :left, tellwidth = false)
Label(fig[1, 1], tell(f -> f.clock); color = INK, fontsize = 26, halign = :right, tellwidth = false)

every = [v for a in ACTS for v in vcat(collect(values(a.planned)), collect(values(a.closed)))]
low_, high = min(minimum(every), 0) / 100, maximum(every) / 100
ax = Axis(fig[2, 1]; backgroundcolor = BACKGROUND,
          limits = (0.4, length(DAYS) + 0.6, low_ - 0.12 * (high - low_), high + 0.1 * (high - low_)),
          xticks = (1:length(DAYS), [uppercase(Dates.format(d, dateformat"e dd")) for d in DAYS]),
          ytickformat = values -> [money(round(Int, v) * 100)[1:end-3] for v in values],
          xticklabelcolor = MUTED, yticklabelcolor = MUTED, xticklabelsize = 19, yticklabelsize = 21,
          xgridvisible = false, ygridcolor = (RAIL, 0.45), ygridstyle = :dot,
          xtickcolor = RAIL, ytickcolor = RAIL, topspinevisible = false, rightspinevisible = false,
          leftspinecolor = RAIL, bottomspinecolor = RAIL)
hlines!(ax, [0]; color = RAIL_TEXT, linewidth = 2)

# The floor: furniture, until a statement is under it.
hlines!(ax, [FLOOR / 100]; color = tell(s -> s.under ? PROBLEM : RAIL_TEXT), linewidth = 2, linestyle = :dash)
text!(ax, 0.5, FLOOR / 100; text = "FLOOR $(money(FLOOR)[1:end-3])",
      color = tell(s -> s.under ? PROBLEM : RAIL_TEXT), fontsize = 21, align = (:left, :bottom), offset = (4, 2))

lines!(ax, tell(s -> upto(steps(ACTS[s.act].planned), s.reach)); color = MUTED, linewidth = 4)

# Each hold: from the day a run would have paid it to the day the plan does.
mark(s) = [(h, (ACTS[s.act].planned[h.from] / 100 + high) / 2) for h in ACTS[s.act].holds
           if haskey(X, h.from) && haskey(X, h.to)]
linesegments!(ax, tell(s -> s.moved == 0 ? Point2f[] :
    [p for (h, level) in mark(s) for p in (Point2f(X[h.from], level),
                                           Point2f(X[h.from] + s.moved * (X[h.to] - X[h.from]), level))]);
    color = INK, linewidth = 2)
scatter!(ax, tell(s -> s.moved < 1 ? Point2f[] : [Point2f(X[h.to], level) for (h, level) in mark(s)]);
         marker = :rtriangle, markersize = 14, color = INK)
text!(ax, tell(s -> s.moved == 0 ? Point2f[] : [Point2f(X[h.from], level) for (h, level) in mark(s)]);
      text = tell(s -> s.moved == 0 ? String[] : [h.reference for (h, _) in mark(s)]),
      color = INK, fontsize = 21, align = (:right, :center), offset = (-8, 0))

linesegments!(ax, tell() do s
    gaps = Point2f[]
    for (day, x) in X
        s.missed[x] && s.landed[x] > 0 || continue
        push!(gaps, Point2f(x, ACTS[s.act].planned[day] / 100), Point2f(x, ACTS[s.act].closed[day] / 100))
    end
    gaps
end; color = PROBLEM, linewidth = 3, linestyle = :dash)
scatter!(ax, tell(s -> [Point2f(X[day], ACTS[s.act].closed[day] / 100) for day in DAYS]); marker = :rect,
         markersize = tell(s -> 16 .* s.landed),
         color = tell(s -> [miss ? PROBLEM : INK for miss in s.missed]))

Label(fig[3, 1], tell(s -> s.status * "_"); color = tell(s -> s.alarm ? PROBLEM : INK),
      fontsize = 26, halign = :left, tellwidth = false)
rowgap!(fig.layout, 6)

scanlines!(fig)
film(fig, FILM, "treasury_late") do frame
    shown[] = frame
end
