# Record the films as they are now: julia --project=. film/record.jl
#
# After rendering. Writes docs/films/<name>.sha256 for each film in
# docs/films/words.json, and docs/films/index.json. See films.jl.

include(joinpath(@__DIR__, "films.jl"))
record()
foreach(f -> println(f.name, "  ", f.sha256[1:12], "  ", f.updated), manifest().films)
