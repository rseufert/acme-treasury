# The look both films share, which is mock-films': a phosphor terminal in
# VT323, 800 by 450, twenty frames a second, red for a problem and for nothing
# else.

using CairoMakie
using Dates
using JSON

const BACKGROUND, INK, MUTED = "#030806", "#52F58A", "#2FAE5C"
const RAIL, RAIL_TEXT, PROBLEM = "#1A6638", "#23854A", "#FF3B30"
const FACE = "VT323"
const FPS = 20
const KEYS = 2              # characters typed in a frame
const BEAT, WAIT, FINAL = 0.85, 1.5, 4.5

Makie.FreeTypeAbstraction.findfont(FACE) === nothing &&
    error("the font $FACE is not installed, and the look is set in it: brew install --cask font-vt323")

function money(minor::Integer)
    whole, fraction = divrem(abs(minor), 100)
    string(minor < 0 ? "-" : "", replace(string(whole), r"(?<=\d)(?=(\d{3})+$)" => ","),
           ".", lpad(fraction, 2, '0'))
end
stamp(day::Date) = uppercase(Dates.format(day, dateformat"e dd u"))

"As much of a line as lies left of `x`."
function upto(points, x)
    shown = Point2f[]
    for (a, b) in zip(points, Iterators.drop(points, 1))
        isempty(shown) && a[1] <= x && push!(shown, a)
        if b[1] <= x
            push!(shown, b)
        elseif a[1] < x
            push!(shown, Point2f(x, a[2]))      # part way along a flat stretch
        end
    end
    shown
end

"Scanlines, over everything: two dark pixels in every five."
scanlines!(fig) = linesegments!(fig.scene, [Point2f(x, y) for y in 0:5:450 for x in (0, 800)];
                                color = ("#000000", 0.16), linewidth = 2)

"Record `frames` to docs/films/`name`.mp4 and .gif, showing each with `show`."
function film(show, fig, frames, name)
    for extension in ("mp4", "gif")
        path = joinpath(@__DIR__, "..", "docs", "films", "$name.$extension")
        record(show, fig, path, frames; framerate = FPS, px_per_unit = 1)
        println(path, "  ", length(frames), " frames, ", round(length(frames) / FPS; digits = 1), "s")
    end
end
