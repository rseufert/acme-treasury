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

                # Plan, apply, then the run: the order the README gives.
                paid = String[]
                mornings = Forecast[]
                for today in Date(2026, 10, 5):Day(1):Date(2026, 10, 7)
                    today == Date(2026, 10, 7) && bankpost(bank, "/_mock/credits",
                        Dict("account" => "ACME", "amount" => 4_250_000, "note" => "your invoice $owed",
                             "debtor" => Dict("name" => "Customer Ltd", "iban" => "NL14MOCK0000000002")))
                    today == Date(2026, 10, 5) || @test acme("--apply") == 0
                    push!(mornings, forecast(snapshot(sap, bank, "ACME"), scenario))
                    run = world(sap, bank, "morning")
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
    end
end
