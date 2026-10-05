# The films the README shows are the films the code makes. Nothing renders:
# each committed GIF has a `.sha256` of what it was rendered from, and the
# manifest says what the GIF is. See film/films.jl.

include(joinpath(@__DIR__, "..", "film", "films.jl"))

@testset "the films" begin
    films = words()
    named(suffix) = sort!([chopsuffix(f, suffix) for f in readdir(FILMS) if endswith(f, suffix)])
    @test !isempty(films)
    @test named(".gif") == named(".sha256") == sort!(collect(keys(films)))
    fix = "render it again, then: julia --project=. film/record.jl"
    for (name, film) in films
        changed = [path for ((was, _), (now, path)) in zip(recorded(name), digests(film)) if was != now]
        isempty(changed) || @warn "docs/films/$name.gif is stale: $(join(changed, ", ")) changed since; $fix"
        @test last.(recorded(name)) == inputs(film)
        @test isempty(changed)
    end
    # The manifest is what recording now would write: the GIFs' own hashes and
    # sizes, the captures' versions and sources, and the words as they stand.
    @test JSON.parse(JSON.json(manifest())) == JSON.parsefile(MANIFEST)
    @test all(f -> (f.width, f.height) == (800, 450), manifest().films)
end
