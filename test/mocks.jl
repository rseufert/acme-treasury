# The forecast held to what the bank then says happened.
#
# Both mocks are started here on a pinned clock, a week is played forward one
# morning at a time with mock-acme's payment run, and every closing balance
# forecast is compared with the camt.053 the bank issues for that day.
#
# Without a Python that has the mocks installed these tests are skipped, and
# say so: see harness.jl.

include("harness.jl")

look(sap, bank; days = 6) = forecast(snapshot(sap, bank, "ACME"), Scenario(; days))

"Every day both the forecast and the bank have a figure for, as (day, forecast, statement)."
function compared(f, actual)
    [(d.day, d.closing, actual[d.day]) for d in f.days if haskey(actual, d.day)]
end

const PAYER = Dict("name" => "Customer Ltd", "iban" => "NL14MOCK0000000002")

"The week `bin/demo` forecasts. Returns the document the customer will quote."
function demoweek(sap, bank)
    world(sap, bank, "reset")
    world(sap, bank, "payable", GLOBEX, "INV-A", "1200.00", "2026-10-05")
    world(sap, bank, "payable", UMBRELLA, "INV-B", "80800.00", "2026-10-07")
    world(sap, bank, "payable", GLOBEX, "INV-C", "50.00", "2026-10-05", "A")
    world(sap, bank, "payable", UMBRELLA, "INV-E", "61450.00", "2026-10-10")       # a Saturday
    owed = world(sap, bank, "receivable", CUSTOMER, "42500.00", "2026-10-13")["ACCOUNTINGDOCUMENT"]
    bankpost(bank, "/_mock/credits", Dict("account" => "ACME", "amount" => 200_000,
             "value_date" => "2026-10-06", "note" => "PAYMENT", "debtor" => PAYER))
    owed
end

"""
Play from the mocks' Monday to `last`, a morning at a time, in the order the
README gives: the bank's statements, then `plan --apply` when there is a
`floor`, then mock-acme's payment run. `before(today)` is the world's turn
each morning, `upto` is how late the plan allows customers to be, and `some`
how many of them at once. Returns
each morning's forecast and plan, the day each invoice was first paid, the
invoices the run paid more than once, and what the statements say each day
closed at.
"""
function played(sap, bank; last, floor = nothing, upto = 0, some = -1, before = today -> nothing)
    forecasts, plans, paid, twice = Forecast[], Plan[], Dict{String,Date}(), String[]
    for today in Date(START[1:10]):Day(1):last
        before(today)
        world(sap, bank, "statements")
        days = count(d -> dayofweek(d) <= 5, today:Day(1):last)
        scenario = Scenario(; days, floor = something(floor, 0), customerslateupto = upto, latecustomers = some)
        if floor !== nothing
            snap = snapshot(sap, bank, "ACME")
            plan = planpayments(snap, scenario)
            written = apply(sap, changes(snap, plan), scenario.holdcode)
            any(c -> c.outcome == :refused, written) && error("SAP refused a block")
            push!(plans, plan)
        end
        push!(forecasts, forecast(snapshot(sap, bank, "ACME"), scenario))
        for item in world(sap, bank, "run")["items"]
            item["status"] == "accepted" || continue
            haskey(paid, item["reference"]) ? push!(twice, item["reference"]) : (paid[item["reference"]] = today)
        end
        night(sap, bank)
    end
    (; forecasts, plans, paid, twice, actual = statements(bank))
end

"Every closing balance every morning's forecast gave is that day's statement."
agrees(week, forecasts = week.forecasts) =
    all(all(row -> row[2] == row[3], compared(f, week.actual)) for f in forecasts)
holding(plan) = Set(h.reference for h in plan.holds)

if !havemocks()
    @warn "mock-sap, mock-bank and mock-acme are not installed for $PYTHON, so the forecast was " *
          "not checked against them. See the README's Tests section, or set MOCK_PYTHON."
else
    @testset "against the mocks" begin
        @testset "a week, forecast on Monday and every morning after" begin
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", GLOBEX, "INV-A", "1200.00", "2026-10-05")
                world(sap, bank, "payable", UMBRELLA, "INV-B", "800.00", "2026-10-07")
                world(sap, bank, "payable", GLOBEX, "INV-C", "50.00", "2026-10-05", "A")
                world(sap, bank, "payable", UMBRELLA, "INV-E", "450.00", "2026-10-10")     # a Saturday
                owed = world(sap, bank, "receivable", CUSTOMER, "2500.00", "2026-10-08")["ACCOUNTINGDOCUMENT"]
                # A customer's money already on its way, quoting nothing we know.
                bankpost(bank, "/_mock/credits", Dict("account" => "ACME", "amount" => 200_000,
                         "value_date" => "2026-10-06", "note" => "PAYMENT",
                         "debtor" => Dict("name" => "Customer Ltd", "iban" => "NL14MOCK0000000002")))

                monday = look(sap, bank)
                @test [d.closing for d in monday.days] ==
                      [123_800_00, 125_800_00, 125_000_00, 127_500_00, 127_500_00, 127_050_00]
                @test Set(a.reason for a in monday.asides) == Set([:blocked, :overdue])

                mornings = [monday]
                for day in 1:8
                    today = Date(2026, 10, 4) + Day(day)
                    day == 1 || push!(mornings, look(sap, bank))
                    # The customer pays on the due date, and quotes our document.
                    today == Date(2026, 10, 8) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 250_000, "note" => "your invoice $owed",
                             "debtor" => Dict("name" => "Customer Ltd", "iban" => "NL14MOCK0000000002")))
                    # The run reports a customer's credit as money it does not clear,
                    # which is right, and it is the only thing it has to say.
                    @test all(contains("money arriving"), world(sap, bank, "morning")["problems"])
                    night(sap, bank)
                end

                actual = statements(bank)
                @test length(actual) == 6                   # Monday to Monday, no weekend
                for f in mornings
                    rows = compared(f, actual)
                    @test !isempty(rows)
                    @test all(row -> row[2] == row[3], rows)
                end
                # And the blocked invoice was never paid.
                @test actual[Date(2026, 10, 12)] == 127_050_00
            end
        end

        @testset "a return is forecast once the bank knows of it" begin
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", GLOBEX, "INV-A", "1200.00", "2026-10-05")
                bankpatch(bank, "/_mock/accounts/ACME",
                          Dict("behaviour" => "return-later", "parameters" => Dict("days" => 3)))
                world(sap, bank, "morning")
                night(sap, bank)

                tuesday = look(sap, bank)
                @test [x.source for x in tuesday.flows] == [:return, :payable]
                for _ in 1:7
                    world(sap, bank, "morning")
                    night(sap, bank)
                end
                rows = compared(tuesday, statements(bank))
                @test length(rows) == 5                     # Tuesday to Monday
                @test all(row -> row[2] == row[3], rows)
                @test [row[2] for row in rows] ==
                      [123_800_00, 123_800_00, 125_000_00, 123_800_00, 123_800_00]
            end
        end

        @testset "what Monday cannot know: the supplier's account is closed" begin
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", INITECH, "INV-D", "300.00", "2026-10-05")

                monday = look(sap, bank; days = 2)
                @test monday.days[1].closing == 124_700_00          # it expects to pay

                items = world(sap, bank, "morning")["items"]
                @test [(i["status"], i["reason"]) for i in items] == [("rejected", "AC04")]
                night(sap, bank)
                @test statements(bank)[Date(2026, 10, 5)] == 125_000_00     # and nothing left

                tuesday = look(sap, bank; days = 2)
                @test [(a.reason, a.amount) for a in tuesday.asides if a.reference == "INV-D"] ==
                      [(:rejected, -300_00)]
                @test all(d -> d.closing == 125_000_00, tuesday.days)
            end
        end

        @testset "a side that is down is named, with exit status 2" begin
            withmocks() do sap, bank
                dead = "http://127.0.0.1:$(only(freeports(1)))"
                @test_throws "SAP did not answer" snapshot(dead, bank, "ACME")
                @test_throws "the bank did not answer" snapshot(sap, dead, "ACME")
                @test_throws "the bank answered 404" snapshot(sap, bank, "NOBODY")
                @test redirect_stderr(() -> main(["--sap", dead, "--bank", bank]), devnull) == 2
            end
        end
        @testset "a plan applied in SAP: blocked, left alone, lifted on its day" begin
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", UMBRELLA, "INV-B", "80800.00", "2026-10-05")
                world(sap, bank, "payable", GLOBEX, "INV-C", "50.00", "2026-10-05", "A")
                world(sap, bank, "payable", UMBRELLA, "INV-E", "61450.00", "2026-10-06")
                owed = world(sap, bank, "receivable", CUSTOMER, "42500.00", "2026-10-07")["ACCOUNTINGDOCUMENT"]
                scenario = Scenario(days = 4, floor = 10_000_00)
                blocks() = Dict(i.reference => i.block for i in snapshot(sap, bank, "ACME").items
                                if i.reference != "")
                acme(args...) = redirect_stdout(devnull) do
                    main(["plan", "--sap", sap, "--bank", bank, "--days", "4", "--floor", "10000", args...])
                end
                done() = [(c.action, c.reference, c.outcome) for c in
                          apply(sap, changes(snapshot(sap, bank, "ACME"),
                                             planpayments(snapshot(sap, bank, "ACME"), scenario)), "T")]

                # Without the plan Tuesday closes at -17,250.00.
                @test [d.closing for d in look(sap, bank; days = 4).days] ==
                      [44_200_00, -17_250_00, 25_250_00, 25_250_00]
                # Dry by default: the plan is printed and SAP is as it was.
                @test acme() == 0
                @test blocks() == Dict("INV-B" => "", "INV-C" => "A", "INV-E" => "")
                @test acme("--apply") == 0
                @test blocks() == Dict("INV-B" => "", "INV-C" => "A", "INV-E" => "T")
                # The second time there is nothing to do.
                @test done() == [(:block, "INV-E", :already)]

                # The statements, the plan applied, then the run: the order the README gives.
                paid = String[]
                mornings = Forecast[]
                for today in Date(2026, 10, 5):Day(1):Date(2026, 10, 7)
                    today == Date(2026, 10, 7) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 4_250_000, "note" => "your invoice $owed",
                             "debtor" => Dict("name" => "Customer Ltd", "iban" => "NL14MOCK0000000002")))
                    world(sap, bank, "statements")
                    today == Date(2026, 10, 5) || @test acme("--apply") == 0
                    push!(mornings, forecast(snapshot(sap, bank, "ACME"), scenario))
                    run = world(sap, bank, "run")
                    append!(paid, [i["reference"] for i in run["items"] if i["status"] == "accepted"])
                    today == Date(2026, 10, 6) && @test blocks()["INV-E"] == "T"
                    night(sap, bank)
                end
                @test paid == ["INV-B", "INV-E"]
                @test blocks()["INV-C"] == "A"              # somebody else's, and still theirs
                actual = statements(bank)
                @test [actual[Date(2026, 10, d)] for d in 5:7] == [44_200_00, 44_200_00, 25_250_00]
                # And each morning's forecast, knowing the hold, said so.
                for f in mornings
                    @test all(row -> row[2] == row[3], compared(f, actual))
                end
            end
        end

        @testset "a write SAP refuses is named, and the rest still happen" begin
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", GLOBEX, "INV-1", "70000.00", "2026-10-05")
                world(sap, bank, "payable", UMBRELLA, "INV-2", "60000.00", "2026-10-05")
                # A floor nothing can keep, so both are held to the last day.
                scenario = Scenario(days = 3, floor = 100_000_00)
                wanted() = changes(snapshot(sap, bank, "ACME"),
                                   planpayments(snapshot(sap, bank, "ACME"), scenario))
                @test [(c.reference, c.outcome) for c in wanted()] == [("INV-1", :wanted), ("INV-2", :wanted)]
                HTTP.post(sap * "/_mock/faults", ["Content-Type" => "application/json"],
                          JSON.json(Dict("method" => "PATCH", "match" => "A_SupplierInvoice",
                                         "status" => 423, "message" => "locked by MOCKUSER", "count" => 1)))
                written = apply(sap, wanted(), "T")
                @test [(c.reference, c.outcome) for c in written] == [("INV-1", :refused), ("INV-2", :done)]
                @test written[1].message == "SAP answered 423: locked by MOCKUSER"
                @test [(c.reference, c.outcome) for c in wanted()] == [("INV-1", :wanted), ("INV-2", :already)]

                # From the command line: 2 for the refusal, then 1, because the
                # plan is in SAP and still no plan keeps this floor.
                HTTP.post(sap * "/_mock/faults", ["Content-Type" => "application/json"],
                          JSON.json(Dict("method" => "PATCH", "status" => 423, "count" => 1)))
                acme() = redirect_stdout(devnull) do
                    main(["plan", "--apply", "--sap", sap, "--bank", bank, "--days", "3", "--floor", "100000"])
                end
                @test acme() == 2
                @test acme() == 1
                @test all(c -> c.outcome == :already, wanted())
            end
        end
        @testset "the demo week without the schedule: the overdraft is real" begin
            withmocks() do sap, bank
                owed = demoweek(sap, bank)
                week = played(sap, bank; last = Date(2026, 10, 14), before = today ->
                    today == Date(2026, 10, 13) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 4_250_000,
                             "note" => "your invoice $owed", "debtor" => PAYER)))
                @test week.actual[Date(2026, 10, 12)] == -16_450_00
                @test week.actual[Date(2026, 10, 13)] == 26_050_00
                @test week.paid["INV-E"] == Date(2026, 10, 12)
                @test agrees(week)
            end
        end

        @testset "the demo week with the schedule: the statements keep the floor" begin
            withmocks() do sap, bank
                owed = demoweek(sap, bank)
                week = played(sap, bank; last = Date(2026, 10, 14), floor = 10_000_00, before = today ->
                    today == Date(2026, 10, 13) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 4_250_000,
                             "note" => "your invoice $owed", "debtor" => PAYER)))
                @test length(week.actual) == 8
                @test minimum(values(week.actual)) == 26_050_00
                @test week.actual[Date(2026, 10, 12)] == 45_000_00
                # One invoice a business day late, and nothing else moved.
                @test week.paid == Dict("INV-A" => Date(2026, 10, 5), "INV-B" => Date(2026, 10, 7),
                                        "INV-E" => Date(2026, 10, 13))
                # The forecast knows its own holds: every morning's is the statements'.
                @test agrees(week)
                # Monday's plan survives the week: what is held only ever shrinks.
                @test holding(week.plans[1]) == Set(["INV-E"])
                @test all(issubset(holding(b), holding(a)) for (a, b) in zip(week.plans, week.plans[2:end]))
                @test holding(week.plans[8]) == Set(["INV-E"])      # Monday the 12th, its last day held
                @test isempty(holding(week.plans[9]))
                @test all(i -> i.block == (i.reference == "INV-C" ? "A" : ""),
                          filter(i -> i.kind == :payable, snapshot(sap, bank, "ACME").items))
            end
        end

        @testset "a floor the week's money cannot keep: the breach the plan named, on its day" begin
            withmocks() do sap, bank
                owed = demoweek(sap, bank)
                week = played(sap, bank; last = Date(2026, 10, 14), floor = 50_000_00, before = today ->
                    today == Date(2026, 10, 13) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 4_250_000,
                             "note" => "your invoice $owed", "debtor" => PAYER)))
                short = shortfall(week.plans[1])
                @test (short.day, short.closing) == (Date(2026, 10, 14), 26_050_00)
                @test week.actual[short.day] == short.closing
                @test all(closing >= 50_000_00 for (day, closing) in week.actual if day != short.day)
                # Only the large invoice has to wait: with it held, INV-E can go on its day.
                @test week.paid == Dict("INV-A" => Date(2026, 10, 5), "INV-B" => Date(2026, 10, 14),
                                        "INV-E" => Date(2026, 10, 12))
                @test agrees(week)
            end
        end

        @testset "what Monday's plan cannot know: it holds for a payment the bank refuses" begin
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", INITECH, "INV-D", "100000.00", "2026-10-05")    # the closed account
                world(sap, bank, "payable", GLOBEX, "INV-X", "30000.00", "2026-10-05")
                bankpost(bank, "/_mock/credits", Dict("account" => "ACME", "amount" => 2_000_000,
                         "value_date" => "2026-10-06", "note" => "PAYMENT", "debtor" => PAYER))
                week = played(sap, bank; last = Date(2026, 10, 6), floor = 10_000_00)
                monday, tuesday = week.plans
                # Monday: paying both goes under, so the smaller waits a day for the credit.
                @test [d.closing for d in monday.before.days] == [-5_000_00, 15_000_00]
                @test holding(monday) == Set(["INV-X"])
                @test [d.closing for d in monday.forecast.days] == [25_000_00, 15_000_00]
                # The bank refused the large one, so the hold was for nothing, and
                # Monday's statement is out by the invoice.
                @test week.actual[Date(2026, 10, 5)] == 125_000_00
                # Tuesday's plan is made from what happened, and is right.
                @test isempty(holding(tuesday))
                @test [(a.reason, a.amount) for a in tuesday.forecast.asides if a.reference == "INV-D"] ==
                      [(:rejected, -100_000_00)]
                @test week.paid == Dict("INV-X" => Date(2026, 10, 6))
                @test week.actual[Date(2026, 10, 6)] == 115_000_00 == tuesday.forecast.days[1].closing
            end
        end
        # The customer's 42,500.00 is due on Tuesday the 13th. These three play
        # the demo week to Thursday, and differ in when it comes and in whether
        # the plan allowed for that.
        @testset "the customer pays a day late, and the plan trusted the due date" begin
            withmocks() do sap, bank
                owed = demoweek(sap, bank)
                week = played(sap, bank; last = Date(2026, 10, 15), floor = 10_000_00, before = today ->
                    today == Date(2026, 10, 14) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 4_250_000,
                             "note" => "your invoice $owed", "debtor" => PAYER)))
                # The block was lifted on the day the money was due, and it had not come.
                @test week.paid["INV-E"] == Date(2026, 10, 13)
                @test week.actual[Date(2026, 10, 13)] == -16_450_00
                @test week.actual[Date(2026, 10, 14)] == 26_050_00
            end
        end

        @testset "the customer pays a day late, and the plan allowed for it" begin
            withmocks() do sap, bank
                owed = demoweek(sap, bank)
                week = played(sap, bank; last = Date(2026, 10, 15), floor = 10_000_00, upto = 1, before = today ->
                    today == Date(2026, 10, 14) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 4_250_000,
                             "note" => "your invoice $owed", "debtor" => PAYER)))
                @test minimum(values(week.actual)) == 26_050_00
                @test week.actual[Date(2026, 10, 13)] == 45_000_00
                @test week.paid == Dict("INV-A" => Date(2026, 10, 5), "INV-B" => Date(2026, 10, 7),
                                        "INV-E" => Date(2026, 10, 14))
                @test [(h.reference, h.to, h.days) for h in week.plans[1].holds] ==
                      [("INV-E", Date(2026, 10, 14), 2)]
                # The case that came true is the one the statements are: every
                # morning's forecast with customers a day late.
                @test agrees(week, [plan.cases[2] for plan in week.plans])
                @test all(issubset(holding(b), holding(a)) for (a, b) in zip(week.plans, week.plans[2:end]))
            end
        end

        @testset "the customer pays on time, and the plan had allowed for a day late" begin
            withmocks() do sap, bank
                owed = demoweek(sap, bank)
                week = played(sap, bank; last = Date(2026, 10, 15), floor = 10_000_00, upto = 1, before = today ->
                    today == Date(2026, 10, 13) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 4_250_000,
                             "note" => "your invoice $owed", "debtor" => PAYER)))
                @test minimum(values(week.actual)) == 26_050_00
                # Monday's plan held INV-E to Wednesday. The plan is made again
                # each morning, and on Tuesday the money was at the bank, so the
                # caution cost nothing more: it went that day.
                @test [(h.reference, h.to) for h in week.plans[1].holds] == [("INV-E", Date(2026, 10, 14))]
                @test week.paid["INV-E"] == Date(2026, 10, 13)
                @test week.actual[Date(2026, 10, 13)] == 26_050_00
                # So the forecasts made before Tuesday were out for Tuesday, by
                # the invoice: they said it would wait. From Tuesday they are right.
                @test compared(week.forecasts[1], week.actual)[7] ==
                      (Date(2026, 10, 13), 87_500_00, 26_050_00)
                @test agrees(week, week.forecasts[9:end])
            end
        end
        @testset "a run's claim is read from SAP, and is SAP's word" begin
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", GLOBEX, "INV-A", "1200.00", "2026-10-05")
                world(sap, bank, "payable", GLOBEX, "INV-B", "800.00", "2026-10-07")
                world(sap, bank, "run")
                snap = snapshot(sap, bank, "ACME")
                @test Dict(i.reference => (i.run, i.rundate) for i in snap.items if i.reference != "") ==
                      Dict("INV-A" => ("R1", Date(2026, 10, 5)), "INV-B" => ("", nothing))
                # With the bank's list taken away, SAP alone says INV-A is in
                # payment: it goes out on the run's day, and no plan holds it.
                blind = Snapshot(; account = snap.account, currency = snap.currency, now = snap.now,
                                 today = snap.today, pastcutoff = snap.pastcutoff, calendar = snap.calendar,
                                 position = snap.position, items = snap.items,
                                 payments = BankPayment[], credits = snap.credits)
                f = forecast(blind, Scenario(days = 3))
                @test [(x.day, x.note) for x in f.flows if x.reference == "INV-A"] ==
                      [(Date(2026, 10, 5), "in payment run R1 of 2026-10-05")]
                @test isempty(planpayments(blind, Scenario(days = 3, floor = 10_000_000_00)).holds)
            end
        end

        @testset "two suppliers, one invoice number: a settled payment is nobody else's" begin
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", GLOBEX, "INV-7", "60000.00", "2026-10-05")
                world(sap, bank, "payable", UMBRELLA, "INV-7", "60000.00", "2026-10-07")
                bankpost(bank, "/_mock/credits", Dict("account" => "ACME", "amount" => 4_000_000,
                         "value_date" => "2026-10-08", "note" => "PAYMENT", "debtor" => PAYER))
                week = played(sap, bank; last = Date(2026, 10, 8), floor = 10_000_00)
                # Monday's run pays Globex, and Monday's statement settles its
                # item. From Tuesday the bank's one payment fits Umbrella's open
                # twin alone, and is not its: every morning's plan holds
                # Umbrella's invoice to Thursday, when the customer's money is in.
                @test [held(p) for p in week.plans] ==
                      [fill([("INV-7", Date(2026, 10, 7), Date(2026, 10, 8), 1)], 3)..., []]
                @test week.twice == ["INV-7"]       # one number, paid once for each supplier
                @test [week.actual[Date(2026, 10, d)] for d in 5:8] == [65_000_00, 65_000_00, 65_000_00, 45_000_00]
                @test agrees(week)
            end
        end

        # Every day here is played at 16:00, an hour after the bank's cutoff, so
        # what a run sends settles on the next business day, and the next day's
        # run starts before the statement that would clear the item. SAP still
        # shows it open. What keeps the run from paying it again is mock-acme's
        # register of what it has sent, which test/world.py keeps in a file.
        late_in_the_day(body; kw...) = withmocks(; start = "2026-10-05T16:00", kw...) do sap, bank
            world(sap, bank, "reset")
            world(sap, bank, "payable", GLOBEX, "INV-X", "120000.00", "2026-10-05")
            bankpost(bank, "/_mock/credits", Dict("account" => "ACME", "amount" => 2_000_000,
                     "value_date" => "2026-10-08", "note" => "PAYMENT", "debtor" => PAYER))
            body(sap, bank)
        end

        @testset "after the cutoff, without the schedule: paid today, short tomorrow" begin
            late_in_the_day() do sap, bank
                week = played(sap, bank; last = Date(2026, 10, 9))
                @test week.forecasts[1].pastcutoff
                @test week.paid == Dict("INV-X" => Date(2026, 10, 5))
                @test isempty(week.twice)
                @test [week.actual[Date(2026, 10, d)] for d in 5:9] ==
                      [125_000_00, 5_000_00, 5_000_00, 25_000_00, 25_000_00]
                @test agrees(week)
            end
        end

        @testset "after the cutoff, with the schedule: the block is lifted the evening before" begin
            late_in_the_day() do sap, bank
                week = played(sap, bank; last = Date(2026, 10, 9), floor = 10_000_00)
                # The plan is in days the money moves: held from Tuesday, when
                # Monday's run would have settled, to Thursday, when the credit books.
                @test [(h.reference, h.from, h.to, h.days) for h in week.plans[1].holds] ==
                      [("INV-X", Date(2026, 10, 6), Date(2026, 10, 8), 2)]
                # So the run that pays it is Wednesday's, after that day's cutoff.
                @test week.paid == Dict("INV-X" => Date(2026, 10, 7))
                @test isempty(week.twice)
                @test isempty(holding(week.plans[3]))
                @test [week.actual[Date(2026, 10, d)] for d in 5:9] ==
                      [125_000_00, 125_000_00, 125_000_00, 25_000_00, 25_000_00]
                @test agrees(week)
            end
        end

        # Two customers, Ann and Bob, each owe money on Tuesday the 6th, and two
        # invoices are due that day which need both. One of them pays a day late.
        ann, bob = CUSTOMER, "1000003"
        function twocustomers(body; late, kw...)
            withmocks() do sap, bank
                world(sap, bank, "reset")
                world(sap, bank, "payable", UMBRELLA, "INV-0", "105000.00", "2026-10-05")
                world(sap, bank, "payable", GLOBEX, "INV-1", "30000.00", "2026-10-06")
                world(sap, bank, "payable", UMBRELLA, "INV-2", "25000.00", "2026-10-06")
                owed = Dict(who => world(sap, bank, "receivable", who, amount, "2026-10-06")["ACCOUNTINGDOCUMENT"]
                            for (who, amount) in ((ann, "30000.00"), (bob, "20000.00")))
                pays(who, cents) = bankpost(bank, "/_mock/credits", Dict("account" => "ACME", "amount" => cents,
                    "note" => "your invoice $(owed[who])", "debtor" => PAYER))
                body(played(sap, bank; last = Date(2026, 10, 8), floor = 5_000_00, kw..., before = today -> begin
                    today == Date(2026, 10, 6) + Day(late == ann) && pays(ann, 3_000_000)
                    today == Date(2026, 10, 6) + Day(late == bob) && pays(bob, 2_000_000)
                end))
            end
        end
        tuesday, wednesday = Date(2026, 10, 6), Date(2026, 10, 7)

        @testset "one of two customers pays late, and the plan trusted the due dates" begin
            twocustomers(late = ann) do week
                @test isempty(holding(week.plans[1]))
                @test week.actual[tuesday] == -15_000_00
            end
        end

        @testset "one of two customers pays late, and the plan allowed for any one" begin
            # Whichever of them it is.
            for (late, tuesdays) in ((ann, 10_000_00), (bob, 20_000_00))
                twocustomers(; late, upto = 1, some = 1) do week
                    @test minimum(values(week.actual)) >= 5_000_00
                    @test week.actual[tuesday] == tuesdays
                    @test week.actual[wednesday] == 15_000_00
                    # Monday's plan is for the larger of the two being the late one.
                    @test [(h.reference, h.to) for h in week.plans[1].holds] == [("INV-2", wednesday)]
                    @test week.plans[1].late == Dict(ann => 1)
                    @test week.paid == Dict("INV-0" => Date(2026, 10, 5), "INV-1" => tuesday, "INV-2" => wednesday)
                    @test isempty(week.twice)
                end
            end
        end

        @testset "one of two customers pays late, and the plan allowed for both" begin
            twocustomers(late = ann, upto = 1) do week
                @test minimum(values(week.actual)) >= 5_000_00
                # Monday's plan held both invoices, where allowing for one held one.
                @test holding(week.plans[1]) == Set(["INV-1", "INV-2"])
                @test helddays(week.plans[1]) == 2
            end
        end
    end
end
