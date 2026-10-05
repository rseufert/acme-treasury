# Capture the run the second film shows: julia --project=. film/capture_plan.jl
#
# The week `bin/demo` forecasts, with a floor of 10,000.00. On Monday the
# forecast is taken as it would be with nothing held, and then every morning
# goes as the README says: the bank's statements, `plan --apply`, the payment
# run. What is written to film/plan.json is the first forecast, each morning's
# plan as the command prints it with --json, each run and each statement, and
# the film is drawn from that file alone.

using AcmeTreasury
using Dates

include(joinpath(@__DIR__, "..", "test", "harness.jl"))

const FIRST, LAST = Date(2026, 10, 5), Date(2026, 10, 14)
const FLOOR = 10_000_00
const OUT = joinpath(@__DIR__, "plan.json")

withmocks() do sap, bank
    world(sap, bank, "reset")
    world(sap, bank, "payable", GLOBEX, "INV-A", "1200.00", "2026-10-05")
    world(sap, bank, "payable", UMBRELLA, "INV-B", "80800.00", "2026-10-07")
    world(sap, bank, "payable", GLOBEX, "INV-C", "50.00", "2026-10-05", "A")
    world(sap, bank, "payable", UMBRELLA, "INV-E", "61450.00", "2026-10-10")
    owed = world(sap, bank, "receivable", CUSTOMER, "42500.00", "2026-10-13")["ACCOUNTINGDOCUMENT"]
    payer = Dict("name" => "Customer Ltd", "iban" => "NL14MOCK0000000002")
    bankpost(bank, "/_mock/credits", Dict("account" => "ACME", "amount" => 200_000,
             "value_date" => "2026-10-06", "note" => "PAYMENT", "debtor" => payer))

    unplanned, plans, runs = nothing, [], []
    for today in FIRST:Day(1):LAST
        today == Date(2026, 10, 13) && bankpost(bank, "/_mock/credits",
            Dict("account" => "ACME", "amount" => 4_250_000, "note" => "your invoice $owed", "debtor" => payer))
        world(sap, bank, "statements")
        days = count(d -> dayofweek(d) <= 5, today:Day(1):LAST)
        scenario = Scenario(; days, floor = FLOOR)
        snap = snapshot(sap, bank, "ACME")
        today == FIRST && (unplanned = JSON.parse(asjson(forecast(snap, scenario))))
        plan = planpayments(snap, scenario)
        written = apply(sap, changes(snap, plan), scenario.holdcode)
        push!(plans, JSON.parse(asjson(plan, written; applied = true)))
        push!(runs, world(sap, bank, "run"))
        night(sap, bank)
    end
    versions = split(read(`$PYTHON -c "from importlib.metadata import version as v; print(v('mock-sap'), v('mock-bank'), v('mock-acme'))"`, String))
    captured = Dict(
        "source" => "acme-treasury film/capture_plan.jl; clocks pinned $START",
        "versions" => Dict(zip(("mock-sap", "mock-bank", "mock-acme"), versions)),
        "account" => "ACME", "currency" => "EUR", "floor" => FLOOR,
        "unplanned" => unplanned,
        "plans" => plans,
        "runs" => runs,
        "statements" => [Dict("day" => string(day), "closing" => closing)
                         for (day, closing) in sort(collect(statements(bank)))])
    write(OUT, JSON.json(captured, 2), "\n")
    println("wrote ", OUT)
end
