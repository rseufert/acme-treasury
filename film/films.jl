# What a committed film was made from, and the manifest of published films.
#
# The layout is mock-films', so whatever reads its docs/films/index.json reads
# this one: one entry for each film, with its name (stable for the life of the
# film), the GIF's hash and size, the mocks and versions it was captured from,
# the capture's own `source`, and the words that go with it. The numbers are
# never typed: they are read from the GIF and from the capture. The words are
# in docs/films/words.json, edited by hand and reviewed like code, with the
# capture and the renderer each film is made from.
#
# Beside each GIF a `.sha256` lists what it was rendered from, in the format
# `shasum -a 256 -c` reads: the capture, its renderer and film/look.jl. The
# tests fail when any of them has changed since, so the README cannot show a
# film the code no longer makes.

using Dates
using JSON
using SHA

const ROOT = normpath(joinpath(@__DIR__, ".."))
const FILMS = joinpath(ROOT, "docs", "films")
const MANIFEST = joinpath(FILMS, "index.json")
const WORDS = joinpath(FILMS, "words.json")

words() = JSON.parsefile(WORDS)
digest(path) = bytes2hex(sha256(read(joinpath(ROOT, path))))

"The files a film is made from, as paths from the repository root, in a fixed order."
inputs(film) = [film["fixture"], film["renderer"], "film/look.jl"]
digests(film) = [(digest(path), path) for path in inputs(film)]
recorded(name) = [Tuple(String.(split(line))) for line in eachline(joinpath(FILMS, name * ".sha256"))]

"(sha256 of the bytes, width, height) of a GIF, read from the file."
function gif(name)
    data = read(joinpath(FILMS, name * ".gif"))
    String(data[1:6]) in ("GIF87a", "GIF89a") || error("docs/films/$name.gif is not a GIF")
    bytes2hex(sha256(data)), Int(data[7]) | Int(data[8]) << 8, Int(data[9]) | Int(data[10]) << 8
end

"""
A film's entry in the manifest. `updated` moves only when the GIF's bytes do,
and a film already listed keeps its `status`: one that is pulled is marked
`withdrawn` by hand, and never dropped.
"""
function entry(name, film, previous, today)
    capture = JSON.parsefile(joinpath(ROOT, film["fixture"]))
    hash, width, height = gif(name)
    unchanged = previous !== nothing && previous["sha256"] == hash
    found = (; name, path = "docs/films/$name.gif",
             status = previous === nothing ? "finished" : previous["status"],
             sha256 = hash, width, height, mocks = film["mocks"],
             mock_versions = NamedTuple(Symbol(mock) => capture["versions"][mock] for mock in film["mocks"]),
             alt = film["alt"], caption = film["caption"], source = capture["source"],
             updated = unchanged ? previous["updated"] : string(today))
    haskey(film, "poster_ms") ? merge(found, (; poster_ms = film["poster_ms"])) : found
end

"The manifest as it would be written now, every film in words.json, by name."
function manifest(today = Dates.today())
    previous = isfile(MANIFEST) ? Dict(f["name"] => f for f in JSON.parsefile(MANIFEST)["films"]) : Dict()
    all = words()
    (; films = [entry(name, all[name], get(previous, name, nothing), today) for name in sort!(collect(keys(all)))])
end

"Write each film's `.sha256` and the manifest."
function record()
    for (name, film) in words()
        write(joinpath(FILMS, name * ".sha256"), join(("$hash  $path\n" for (hash, path) in digests(film))))
    end
    write(MANIFEST, JSON.json(manifest(), 2), "\n")
end
