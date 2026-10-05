# Capture the run the third film shows: julia --project=. film/capture_late.jl
#
# The demo week with a floor of 10,000.00, and the customer paying their
# 42,500.00 on Wednesday the 14th, a day after it is due. It is played twice
# from the same Monday morning, each time as the README says: the bank's
# statements, `plan --apply`, the payment run.
#
#   1. The plan trusts the due date.
#   2. The plan allows for customers a business day late.
#
# What is written to film/late.json is, for each, every morning's plan as the
# command prints it with --json, each run and each statement, and the film is
# drawn from that file alone.

using AcmeTreasury
using Dates

include(joinpath(@__DIR__, "..", "test", "harness.jl"))

const FIRST, LAST = Date(2026, 10, 5), Date(2026, 10, 15)
const FLOOR = 10_000_00
const OUT = joinpath(@__DIR__, "late.json")

function play(upto)
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

        plans, runs = [], []
        for today in FIRST:Day(1):LAST
            today == Date(2026, 10, 14) && bankpost(bank, "/_mock/credits",
                Dict("account" => "ACME", "amount" => 4_250_000, "note" => "your invoice $owed", "debtor" => payer))
            world(sap, bank, "statements")
            days = count(d -> dayofweek(d) <= 5, today:Day(1):LAST)
            scenario = Scenario(; days, floor = FLOOR, customerslateupto = upto)
            snap = snapshot(sap, bank, "ACME")
            plan = planpayments(snap, scenario)
            trusting = upto > 0 ? planpayments(snap, Scenario(; days, floor = FLOOR)) : nothing
            written = apply(sap, changes(snap, plan), scenario.holdcode)
            push!(plans, JSON.parse(asjson(plan, written; applied = true, trusting)))
            push!(runs, world(sap, bank, "run"))
            night(sap, bank)
        end
        Dict("customersLateUpTo" => upto, "plans" => plans, "runs" => runs,
             "statements" => [Dict("day" => string(day), "closing" => closing)
                              for (day, closing) in sort(collect(statements(bank)))])
    end
end

acts = [play(0), play(1)]
versions = split(read(`$PYTHON -c "from importlib.metadata import version as v; print(v('mock-sap'), v('mock-bank'), v('mock-acme'))"`, String))
captured = Dict(
    "source" => "acme-treasury film/capture_late.jl; clocks pinned $START; the customer's credit posted on 2026-10-14",
    "versions" => Dict(zip(("mock-sap", "mock-bank", "mock-acme"), versions)),
    "account" => "ACME", "currency" => "EUR", "floor" => FLOOR,
    "acts" => acts)
write(OUT, JSON.json(captured, 2), "\n")
println("wrote ", OUT)
