# Both mocks on a pinned clock, and the world around them: what the tests and
# the film's capture share.
#
# It needs a Python that has mock-sap, mock-bank and mock-acme installed:
# MOCK_PYTHON, or python3.

using HTTP
using JSON
using Sockets

const PYTHON = get(ENV, "MOCK_PYTHON", "python3")
const WORLD = joinpath(@__DIR__, "world.py")
const START = "2026-10-05T09:00"                    # a Monday morning, before the cutoff
const GLOBEX, INITECH, UMBRELLA = "1000013", "1000014", "1000016"   # suppliers, as mock-sap seeds them
const CUSTOMER = "1000006"

havemocks() = success(pipeline(`$PYTHON -c "import mocksap, mockbank, mockacme.payment_run"`;
                               stdout = devnull, stderr = devnull))

"Ports nothing listens on: bound together, so they differ, then let go."
function freeports(n)
    held = [listenany(ip"127.0.0.1", 18000) for _ in 1:n]
    foreach(h -> close(h[2]), held)
    [Int(h[1]) for h in held]
end

function answers(url)
    for _ in 1:100
        try
            HTTP.get(url * "/_mock/health"; retry = false, connect_timeout = 1).status == 200 && return true
        catch
        end
        sleep(0.1)
    end
    false
end

"Both mocks, started at `start` on their clocks, for as long as `body` runs."
function withmocks(body; start = START)
    sapport, bankport = freeports(2)
    quiet = (stdout = devnull, stderr = devnull)
    mocks = [run(pipeline(`$PYTHON -m mocksap --port $sapport --clock $start -q`; quiet...); wait = false),
             run(pipeline(`$PYTHON -m mockbank --port $bankport --clock $start -q`; quiet...); wait = false)]
    sap, bank = "http://127.0.0.1:$sapport", "http://127.0.0.1:$bankport"
    try
        answers(sap) && answers(bank) || error("the mocks did not start")
        # The payment run's register of what it has sent: a file, because each
        # morning's run is a process of its own, and new for each pair of mocks.
        mktempdir() do dir
            withenv(() -> body(sap, bank), "WORLD_REGISTER" => joinpath(dir, "register.json"))
        end
    finally
        foreach(kill, mocks)
    end
end

world(sap, bank, args...) = JSON.parse(read(`$PYTHON $WORLD $sap $bank $args`, String))
bankpost(bank, path, body) = HTTP.post(bank * path, ["Content-Type" => "application/json"], JSON.json(body))
bankpatch(bank, path, body) = HTTP.patch(bank * path, ["Content-Type" => "application/json"], JSON.json(body))

"One night: both clocks to the same hour tomorrow, and the bank issues today's statement."
function night(sap, bank)
    HTTP.post(sap * "/_mock/advance?days=1")
    HTTP.post(bank * "/_mock/advance?days=1")
end

"What the bank's statements say each day closed at."
statements(bank) = Dict(Date(s["day"]) => s["closing"] for s in
                        JSON.parse(String(HTTP.get(bank * "/_mock/accounts/ACME/statements").body)))
