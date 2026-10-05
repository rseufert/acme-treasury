# Capture the run the film shows: julia --project=. film/capture.jl
#
# Both mocks are started on a Monday morning and a week and a half is played.
# Every morning the forecast is taken before the payment run; every night the
# bank issues a statement. What is written to film/week.json is those two
# things and nothing else, and the film is drawn from that file alone.
#
# One supplier's account is closed at the bank and SAP does not know, so
# Monday's forecast is wrong about Monday, and Tuesday's knows why.

using AcmeTreasury
using Dates

include(joinpath(@__DIR__, "..", "test", "harness.jl"))

const FIRST, LAST = Date(2026, 10, 5), Date(2026, 10, 14)
const OUT = joinpath(@__DIR__, "week.json")

withmocks() do sap, bank
    world(sap, bank, "reset")
    world(sap, bank, "payable", GLOBEX, "INV-A", "1200.00", "2026-10-05")
    world(sap, bank, "payable", INITECH, "INV-D", "9300.00", "2026-10-05")     # the closed account
    world(sap, bank, "payable", UMBRELLA, "INV-B", "80800.00", "2026-10-07")
    world(sap, bank, "payable", GLOBEX, "INV-C", "50.00", "2026-10-05", "A")
    world(sap, bank, "payable", UMBRELLA, "INV-E", "61450.00", "2026-10-10")
    owed = world(sap, bank, "receivable", CUSTOMER, "42500.00", "2026-10-13")["ACCOUNTINGDOCUMENT"]
    payer = Dict("name" => "Customer Ltd", "iban" => "NL14MOCK0000000002")
    bankpost(bank, "/_mock/credits", Dict("account" => "ACME", "amount" => 200_000,
             "value_date" => "2026-10-06", "note" => "PAYMENT", "debtor" => payer))

    forecasts, runs = [], []
    for today in FIRST:Day(1):LAST
        days = count(d -> dayofweek(d) <= 5, max(today, FIRST):Day(1):LAST)
        push!(forecasts, JSON.parse(asjson(forecast(snapshot(sap, bank, "ACME"), Scenario(; days)))))
        today == Date(2026, 10, 13) && bankpost(bank, "/_mock/credits",
            Dict("account" => "ACME", "amount" => 4_250_000, "note" => "your invoice $owed", "debtor" => payer))
        push!(runs, world(sap, bank, "morning"))
        night(sap, bank)
    end
    versions = split(read(`$PYTHON -c "from importlib.metadata import version as v; print(v('mock-sap'), v('mock-bank'), v('mock-acme'))"`, String))
    captured = Dict(
        "source" => "acme-treasury film/capture.jl; clocks pinned $START",
        "versions" => Dict(zip(("mock-sap", "mock-bank", "mock-acme"), versions)),
        "account" => "ACME", "currency" => "EUR",
        "forecasts" => forecasts,
        "runs" => runs,
        "statements" => [Dict("day" => string(day), "closing" => closing)
                         for (day, closing) in sort(collect(statements(bank)))])
    write(OUT, JSON.json(captured, 2), "\n")
    println("wrote ", OUT)
end
