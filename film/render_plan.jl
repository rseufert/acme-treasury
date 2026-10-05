# Draw the second film from its capture: julia --project=film film/render_plan.jl
#
# It reads film/plan.json and nothing else: no mock is running, no solver is
# called, and nothing here knows what an open item is. The look is the first
# film's, in look.jl.
#
# What it shows is decided by the capture. The forecast with nothing held is
# drawn, and where it is under the floor it is red. The plan replaces it, and
# then each statement is a green block where it lands on the plan's line, or a
# red one with the distance drawn where it does not. A held invoice is not
# red: holding it is the fix.

include(joinpath(@__DIR__, "look.jl"))

# -- the capture ---------------------------------------------------------------

const RUN = JSON.parsefile(joinpath(@__DIR__, "plan.json"))
const FLOOR = RUN["floor"]
const CLOSED = Dict(Date(s["day"]) => s["closing"] for s in RUN["statements"])
const DAYS = sort(collect(keys(CLOSED)))
const X = Dict(day => i for (i, day) in enumerate(DAYS))
closings(days) = Dict(Date(d["day"]) => d["closing"] for d in days)
const UNPLANNED = closings(RUN["unplanned"]["days"])
const PLAN = RUN["plans"][1]                            # Monday's, which the week is held to
const PLANNED = closings(PLAN["days"])
const HOLDS = [(reference = h["reference"], amount = h["amount"], from = Date(h["from"]),
                to = Date(h["to"]), days = h["days"]) for h in PLAN["holds"]]
"The day the run paid each invoice, as the bank accepted it."
const PAID = Dict(i["reference"] => Date(r["day"]) for r in RUN["runs"] for i in r["items"]
                  if i["status"] == "accepted")

"A forecast as the line it draws: flat across each day, at what the day closes at."
function steps(closing; only = day -> true)
    points = Point2f[]
    for day in DAYS
        (haskey(closing, day) && only(day)) || continue
        push!(points, Point2f(X[day] - 0.5, closing[day] / 100), Point2f(X[day] + 0.5, closing[day] / 100))
    end
    points
end
const UNDER = [day for day in DAYS if get(UNPLANNED, day, FLOOR) < FLOOR]

# -- the story, one frame at a time ---------------------------------------------

Base.@kwdef mutable struct Frame
    clock::String = ""
    status::String = ""
    alarm::Bool = false                 # the status line in red
    first::Float64 = 0.0                # how far the forecast with nothing held is drawn
    breach::Bool = false                # its stretch under the floor, in red
    replaced::Bool = false              # the plan has taken its place
    reach::Float64 = 0.0                # how far the plan's line is drawn
    moved::Float64 = 0.0                # each hold's mark, 0 to 1
    landed::Vector{Float64} = zeros(length(DAYS))       # each statement's block, 0 to 1
    missed::Vector{Bool} = falses(length(DAYS))
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
"Ease a field of the frame from 0 to `to`: it arrives, it does not stop dead."
function ease(field, to; seconds)
    for t in range(0, 1; length = round(Int, seconds * FPS))
        setfield!(now_, field, to * (1 - (1 - t)^3))
        shoot()
    end
end
morning(day) = stamp(day) * " 09:00"
whole(minor) = money(minor)[1:end-3]
across = length(DAYS) + 0.5

now_.clock = morning(first(DAYS))
hold(0.6)
type("> ACME-TREASURY --DAYS $(length(DAYS)) --FLOOR $(replace(whole(FLOOR), "," => ""))")
ease(:first, across; seconds = 1.4)
if isempty(UNDER)
    type("FORECAST. NEVER UNDER THE FLOOR")
else
    now_.breach = true
    worst = argmin(day -> UNPLANNED[day], UNDER)
    type("UNDER THE FLOOR ON $(stamp(worst)): $(money(UNPLANNED[worst]))"; alarm = true)
end
hold(WAIT)

type("> ACME-TREASURY PLAN --APPLY")
hold(0.3)
now_.replaced, now_.breach = true, false
ease(:reach, across; seconds = 1.4)
for h in HOLDS
    type("HOLD $(h.reference) $(money(h.amount)) UNTIL $(stamp(h.to))")
    ease(:moved, 1.0; seconds = 0.4)
    hold(WAIT)
end
low = argmin(day -> PLANNED[day], DAYS)
type("BLOCKED IN SAP. LOWEST IS NOW $(money(PLANNED[low])) ON $(stamp(low))")
hold(WAIT)

for today in first(DAYS):Day(1):last(DAYS)
    if !haskey(CLOSED, today)
        now_.clock = morning(today)
        type("$(stamp(today)). NOTHING SETTLES")
        hold(0.3)
        continue
    end
    # A held invoice, the morning the block is lifted and the run pays it.
    for h in HOLDS
        get(PAID, h.reference, nothing) == today || continue
        now_.clock = morning(today)
        late = h.days == 1 ? "1 DAY LATE" : "$(h.days) DAYS LATE"
        type("BLOCK LIFTED. $(h.reference) PAID $(stamp(today)), $late")
        hold(WAIT)
    end
    said, closed = PLANNED[today], CLOSED[today]
    now_.clock = stamp(today) * " 23:59"
    now_.missed[X[today]] = said != closed
    for t in range(0, 1; length = 6)
        now_.landed[X[today]] = t
        shoot()
    end
    if said == closed
        type("CAMT.053 $(stamp(today)) CLOSES $(money(closed)). AS PLANNED")
        hold(BEAT)
    else
        type("CAMT.053 $(stamp(today)) CLOSES $(money(closed)). OFF BY $(money(abs(closed - said)))"; alarm = true)
        hold(WAIT)
    end
end

under = count(day -> CLOSED[day] < FLOOR, DAYS)
held = sum(h.days for h in HOLDS; init = 0)
cost = isempty(HOLDS) ? "NOTHING HELD" :
       "$(length(HOLDS)) INVOICE$(length(HOLDS) == 1 ? "" : "S"), $held DAY$(held == 1 ? "" : "S") LATE"
now_.clock = morning(last(DAYS) + Day(1))
type("$(length(DAYS)) STATEMENTS. $(under == 0 ? "NONE" : under) UNDER THE FLOOR. COST: $cost"; alarm = under > 0)
hold(FINAL)

# -- the picture ----------------------------------------------------------------

set_theme!(fonts = (; regular = FACE, bold = FACE))
fig = Figure(size = (800, 450), backgroundcolor = BACKGROUND, figure_padding = (18, 22, 10, 12))
shown = Observable(FILM[1])
tell(what) = lift(what, shown)

Label(fig[1, 1], "$(RUN["account"]) $(RUN["currency"])  CLOSING BALANCE"; color = MUTED,
      fontsize = 26, halign = :left, tellwidth = false)
Label(fig[1, 1], tell(f -> f.clock); color = INK, fontsize = 26, halign = :right, tellwidth = false)

every = vcat(collect(values(UNPLANNED)), collect(values(PLANNED)), collect(values(CLOSED)))
low_, high = min(minimum(every), 0) / 100, maximum(every) / 100
ax = Axis(fig[2, 1]; backgroundcolor = BACKGROUND,
          limits = (0.4, length(DAYS) + 0.6, low_ - 0.12 * (high - low_), high + 0.1 * (high - low_)),
          xticks = (1:length(DAYS), [uppercase(Dates.format(d, dateformat"e dd")) for d in DAYS]),
          ytickformat = values -> [money(round(Int, v) * 100)[1:end-3] for v in values],
          xticklabelcolor = MUTED, yticklabelcolor = MUTED, xticklabelsize = 21, yticklabelsize = 21,
          xgridvisible = false, ygridcolor = (RAIL, 0.45), ygridstyle = :dot,
          xtickcolor = RAIL, ytickcolor = RAIL, topspinevisible = false, rightspinevisible = false,
          leftspinecolor = RAIL, bottomspinecolor = RAIL)
hlines!(ax, [0]; color = RAIL_TEXT, linewidth = 2)

# The floor: furniture, until something is under it.
hlines!(ax, [FLOOR / 100]; color = tell(s -> s.breach ? PROBLEM : RAIL_TEXT), linewidth = 2, linestyle = :dash)
text!(ax, 0.5, FLOOR / 100; text = "FLOOR $(whole(FLOOR))", color = tell(s -> s.breach ? PROBLEM : RAIL_TEXT),
      fontsize = 21, align = (:left, :bottom), offset = (4, 2))

# The forecast with nothing held: the line, then what the plan replaced.
lines!(ax, tell(s -> upto(steps(UNPLANNED), s.first));
       color = tell(s -> s.replaced ? RAIL : MUTED), linewidth = tell(s -> s.replaced ? 3 : 4))
linesegments!(ax, tell(s -> s.breach ? steps(UNPLANNED; only = in(UNDER)) : Point2f[]);
              color = PROBLEM, linewidth = 5)
lines!(ax, tell(s -> s.replaced ? upto(steps(PLANNED), s.reach) : Point2f[]); color = MUTED, linewidth = 4)

# Each hold: from the day a run would have paid it to the day the plan does.
for h in HOLDS
    (haskey(X, h.from) && haskey(X, h.to)) || continue
    level = (PLANNED[h.from] / 100 + high) / 2
    linesegments!(ax, tell(s -> s.moved == 0 ? Point2f[] :
                                [Point2f(X[h.from], level), Point2f(X[h.from] + s.moved * (X[h.to] - X[h.from]), level)]);
                  color = INK, linewidth = 2)
    scatter!(ax, tell(s -> s.moved < 1 ? Point2f[] : [Point2f(X[h.to], level)]);
             marker = :rtriangle, markersize = 14, color = INK)
    text!(ax, X[h.from], level; text = h.reference, color = INK, fontsize = 21,
          align = (:right, :center), offset = (-8, 0), visible = tell(s -> s.moved > 0))
end

linesegments!(ax, tell() do s
    gaps = Point2f[]
    for (day, x) in X
        s.missed[x] && s.landed[x] > 0 || continue
        push!(gaps, Point2f(x, PLANNED[day] / 100), Point2f(x, CLOSED[day] / 100))
    end
    gaps
end; color = PROBLEM, linewidth = 3, linestyle = :dash)
scatter!(ax, [Point2f(X[day], CLOSED[day] / 100) for day in DAYS]; marker = :rect,
         markersize = tell(s -> 16 .* s.landed),
         color = tell(s -> [miss ? PROBLEM : INK for miss in s.missed]))

Label(fig[3, 1], tell(s -> s.status * "_"); color = tell(s -> s.alarm ? PROBLEM : INK),
      fontsize = 26, halign = :left, tellwidth = false)
rowgap!(fig.layout, 6)

scanlines!(fig)
film(fig, FILM, "treasury_plan") do frame
    shown[] = frame
end
