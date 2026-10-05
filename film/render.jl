# Draw the film from the capture: julia --project=film film/render.jl
#
# It reads film/week.json and nothing else: no mock is running, and nothing
# here knows what an open item is. The look is mock-films': a phosphor
# terminal in VT323, 800 by 450, twenty frames a second, red for a problem and
# for nothing else.
#
# What it shows is decided by the capture. A statement that closes where the
# forecast said is a green block on the line. One that does not is red, with
# the distance drawn, and the next morning's forecast replaces the line.

include(joinpath(@__DIR__, "look.jl"))

# -- the capture ---------------------------------------------------------------

const WEEK = JSON.parsefile(joinpath(@__DIR__, "week.json"))
const CLOSED = Dict(Date(s["day"]) => s["closing"] for s in WEEK["statements"])
const DAYS = sort(collect(keys(CLOSED)))                # the days the bank issued a statement for
const X = Dict(day => i for (i, day) in enumerate(DAYS))
const FORECASTS = [(taken = Date(first(f["asOf"], 10)),
                    closing = Dict(Date(d["day"]) => d["closing"] for d in f["days"]),
                    refused = [x for x in f["leftOut"] if x["reason"] == "rejected"])
                   for f in WEEK["forecasts"]]

"A forecast as the line it draws: flat across each day, at what the day closes at."
function steps(f)
    points = Point2f[]
    for day in DAYS
        haskey(f.closing, day) || continue
        push!(points, Point2f(X[day] - 0.5, f.closing[day] / 100), Point2f(X[day] + 0.5, f.closing[day] / 100))
    end
    points
end

# -- the story, one frame at a time ---------------------------------------------

Base.@kwdef mutable struct Frame
    clock::String = ""
    status::String = ""
    alarm::Bool = false                 # the status line in red
    current::Int = 0                    # which forecast is the line
    reach::Float64 = 0.0                # how far along it is drawn
    stale::Vector{Int} = Int[]          # forecasts that were replaced
    landed::Vector{Float64} = zeros(length(DAYS))       # each statement's block, 0 to 1
    missed::Vector{Bool} = falses(length(DAYS))
    said::Vector{Int} = zeros(Int, length(DAYS))        # what the line said, the night it was wrong
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
function draw(index, from)
    now_.current = index
    span = length(DAYS) + 0.5 - from
    for t in range(0, 1; length = round(Int, 0.18 * span * FPS))
        now_.reach = from + span * (1 - (1 - t)^3)      # ease out: it arrives, it does not stop dead
        shoot()
    end
end

morning(day) = stamp(day) * " 09:00"

now_.clock = morning(first(DAYS))
hold(0.6)
type("> ACME-TREASURY --DAYS $(length(DAYS))")
draw(1, 0.5)
low = argmin(day -> FORECASTS[1].closing[day], DAYS)
type("FORECAST. LOWEST $(money(FORECASTS[1].closing[low])) ON $(stamp(low))")
hold(BEAT)

for today in first(DAYS):Day(1):last(DAYS)
    tomorrow = today + Day(1)
    if !haskey(CLOSED, today)
        now_.clock = morning(today)
        type("$(stamp(today)). NOTHING SETTLES")
        hold(0.3)
        continue
    end
    said, closed = FORECASTS[now_.current].closing[today], CLOSED[today]
    now_.clock = stamp(today) * " 23:59"
    now_.missed[X[today]], now_.said[X[today]] = said != closed, said
    for t in range(0, 1; length = 6)
        now_.landed[X[today]] = t
        shoot()
    end
    if said == closed
        type("CAMT.053 $(stamp(today)) CLOSES $(money(closed)). AS FORECAST")
        hold(BEAT)
    else
        type("CAMT.053 $(stamp(today)) CLOSES $(money(closed)). OFF BY $(money(abs(closed - said)))"; alarm = true)
        hold(WAIT)
        # The next forecast taken replaces the line, and says what it learned.
        next = findfirst(f -> f.taken > today, FORECASTS)
        next === nothing && continue
        now_.clock = morning(FORECASTS[next].taken)
        type("> ACME-TREASURY")
        push!(now_.stale, now_.current)
        draw(next, X[today] + 0.5)
        for x in FORECASTS[next].refused
            type("LEFT OUT: $(x["reference"]) $(money(abs(x["amount"]))), $(uppercase(x["note"]))")
            hold(WAIT)
        end
    end
end

struck = count(now_.missed)
now_.clock = morning(last(DAYS) + Day(1))
type("$(length(DAYS)) STATEMENTS. $(length(DAYS) - struck) AS FORECAST, $struck NOT, AND IT SAID WHY")
hold(FINAL)

# -- the picture ----------------------------------------------------------------

set_theme!(fonts = (; regular = FACE, bold = FACE))
fig = Figure(size = (800, 450), backgroundcolor = BACKGROUND, figure_padding = (18, 22, 10, 12))
shown = Observable(FILM[1])
tell(what) = lift(what, shown)

Label(fig[1, 1], "$(WEEK["account"]) $(WEEK["currency"])  CLOSING BALANCE"; color = MUTED,
      fontsize = 26, halign = :left, tellwidth = false)
Label(fig[1, 1], tell(f -> f.clock); color = INK, fontsize = 26, halign = :right, tellwidth = false)

every = [v for f in FORECASTS for v in values(f.closing)]
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

for (index, f) in enumerate(FORECASTS)
    lines!(ax, tell(s -> index in s.stale ? steps(f) : Point2f[]); color = RAIL, linewidth = 3)
end
lines!(ax, tell(s -> s.current == 0 ? Point2f[] : upto(steps(FORECASTS[s.current]), s.reach));
       color = MUTED, linewidth = 4)
# How far out a missed forecast was, from where it said to where the day closed.
linesegments!(ax, tell() do s
    gaps = Point2f[]
    for (day, x) in X
        s.missed[x] && s.landed[x] > 0 || continue
        push!(gaps, Point2f(x, s.said[x] / 100), Point2f(x, CLOSED[day] / 100))
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
film(fig, FILM, "treasury_week") do frame
    shown[] = frame
end
