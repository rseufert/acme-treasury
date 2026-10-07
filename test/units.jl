# The forecast is a pure function of a snapshot, so each rule is held here
# without either mock running.

const MON = Date(2026, 10, 5)

snap(; kw...) = Snapshot(; account = "ACME", currency = "EUR", now = DateTime(MON) + Hour(9),
                         today = MON, pastcutoff = false, position = 100_000_00, kw...)
payable(reference, amount, due; kw...) =
    OpenItem(; kind = :payable, document = "1710/2026/" * reference, number = reference,
             party = "1000013", amount, currency = "EUR", due, reference, kw...)
receivable(number, amount, due; kw...) =
    OpenItem(; kind = :receivable, document = "1710/2026/" * number, number,
             party = "1000006", amount, currency = "EUR", due, kw...)
closing(f) = [d.closing for d in f.days]
reasons(f) = [a.reason for a in f.asides]

@testset "money" begin
    @test cents("29496.200") == 2_949_620
    @test cents("1200") == 120_000
    @test cents("-0.5") == -50
    @test_throws ArgumentError cents("1.005")
    @test_throws ArgumentError cents("12,50")
    @test money(-12_380_050) == "-123,800.50"
    @test money(5) == "0.05"
    @test money(100_000_000) == "1,000,000.00"
end

@testset "calendar" begin
    cal = BankCalendar(Set([Date(2026, 10, 6)]))
    @test onorafter(cal, Date(2026, 10, 10)) == Date(2026, 10, 12)      # a Saturday
    @test onorafter(cal, Date(2026, 10, 6)) == Date(2026, 10, 7)        # a holiday
    @test addbusinessdays(cal, MON, 1) == Date(2026, 10, 7)
    @test addbusinessdays(cal, Date(2026, 10, 9), 1) == Date(2026, 10, 12)
end

@testset "nothing owed is a flat line" begin
    f = forecast(snap(), Scenario(days = 3))
    @test [d.day for d in f.days] == [MON, MON + Day(1), MON + Day(2)]
    @test closing(f) == fill(100_000_00, 3)
    @test breach(f) === nothing
end

@testset "a payable leaves on its due date, or the next day the bank settles" begin
    f = forecast(snap(items = [payable("INV-1", 120_000, MON),
                               payable("INV-2", 80_000, Date(2026, 10, 10)),     # a Saturday
                               payable("INV-0", 5_000, Date(2026, 9, 1))]),      # overdue: paid now
                 Scenario(days = 6))
    @test closing(f) == [98_750_00, 98_750_00, 98_750_00, 98_750_00, 98_750_00, 97_950_00]
end

@testset "after the cutoff, today's run settles tomorrow" begin
    f = forecast(snap(pastcutoff = true, items = [payable("INV-1", 120_000, MON)]), Scenario(days = 2))
    @test closing(f) == [100_000_00, 98_800_00]
end

@testset "a forecast taken on a Saturday starts on Monday" begin
    f = forecast(snap(today = Date(2026, 10, 10), items = [payable("INV-1", 120_000, MON)]),
                 Scenario(days = 1))
    @test f.days[1].day == Date(2026, 10, 12)
    @test closing(f) == [98_800_00]
end

@testset "a payment at the bank is not owed twice" begin
    item = payable("INV-1", 120_000, MON)
    inflight = BankPayment(reference = "INV-1", amount = 120_000, currency = "EUR",
                           status = "accepted", settles = MON + Day(1))
    f = forecast(snap(items = [item], payments = [inflight]), Scenario(days = 2))
    @test closing(f) == [100_000_00, 98_800_00]
    @test [x.source for x in f.flows] == [:payment]

    # Booked: it is in the balance already, and SAP has not heard yet.
    booked = BankPayment(reference = "INV-1", amount = 120_000, currency = "EUR",
                         status = "accepted", settles = MON, booked = true)
    f = forecast(snap(items = [item], payments = [booked]), Scenario(days = 2))
    @test closing(f) == [100_000_00, 100_000_00]
end

@testset "a blocked item is listed, not forecast, until the block is assumed lifted" begin
    items = [payable("INV-3", 5_000, MON; block = "A")]
    f = forecast(snap(; items), Scenario(days = 1))
    @test closing(f) == [100_000_00]
    @test reasons(f) == [:blocked]
    @test f.asides[1].amount == -5_000
    @test closing(forecast(snap(; items), Scenario(days = 1, releaseblocked = true))) == [99_950_00]
end

@testset "a payment the bank refused is listed with the bank's reason" begin
    refused = BankPayment(reference = "INV-4", amount = 30_000, currency = "EUR",
                          status = "rejected", reason = "AC04")
    f = forecast(snap(items = [payable("INV-4", 30_000, MON)], payments = [refused]), Scenario(days = 1))
    @test closing(f) == [100_000_00]
    @test reasons(f) == [:rejected]
    @test occursin("AC04", f.asides[1].note)
end

@testset "a payment that will come back comes back, and is owed again" begin
    back = BankPayment(reference = "INV-1", amount = 120_000, currency = "EUR", status = "accepted",
                       settles = MON, booked = true, returndue = MON + Day(3))
    f = forecast(snap(items = [payable("INV-1", 120_000, MON)], payments = [back]), Scenario(days = 5))
    @test closing(f) == [100_000_00, 100_000_00, 100_000_00, 101_200_00, 100_000_00]

    # Once it is back, the open item is simply owed: the newest payment decides.
    returned = BankPayment(reference = "INV-1", amount = 120_000, currency = "EUR", status = "accepted",
                           settles = MON - Day(5), booked = true, returndue = MON - Day(2), returned = true)
    f = forecast(snap(items = [payable("INV-1", 120_000, MON - Day(5); reopened = true)],
                      payments = [returned]), Scenario(days = 1))
    @test closing(f) == [98_800_00]
end

@testset "a receivable arrives on its due date, and an overdue one is not forecast" begin
    items = [receivable("0100000010", 250_000, MON + Day(3)), receivable("0100000001", 999_000, MON - Day(30))]
    f = forecast(snap(; items), Scenario(days = 5))
    @test closing(f) == [100_000_00, 100_000_00, 100_000_00, 102_500_00, 102_500_00]
    @test reasons(f) == [:overdue]

    late = forecast(snap(; items), Scenario(days = 5, customerslate = 2))
    @test closing(late) == [100_000_00, 100_000_00, 100_000_00, 100_000_00, 100_000_00]
    @test reasons(late) == [:overdue, :beyond]      # Thursday plus two business days is Monday
end

@testset "a credit the bank holds replaces the receivable it names" begin
    items = [receivable("0100000010", 250_000, MON + Day(3))]
    naming = BankCredit(amount = 240_000, currency = "EUR", books = MON + Day(1),
                        payer = "Customer Ltd", text = "invoice 01000 00010 less damage")
    f = forecast(snap(; items, credits = [naming]), Scenario(days = 5))
    @test closing(f)[end] == 102_400_00
    @test [x.source for x in f.flows] == [:credit]

    silent = BankCredit(amount = 240_000, currency = "EUR", books = MON + Day(1), text = "PAYMENT")
    f = forecast(snap(; items, credits = [silent]), Scenario(days = 5))
    @test closing(f)[end] == 104_900_00             # a payer who quotes nothing is counted beside it
end

@testset "what cannot be forecast is listed" begin
    f = forecast(snap(items = [
            OpenItem(kind = :payable, document = "1710/2026/7", number = "7", party = "1000013",
                     amount = 100, currency = "USD", due = MON, reference = "INV-7"),
            OpenItem(kind = :payable, document = "1710/2026/8", number = "8", party = "1000013",
                     amount = 100, currency = "EUR", due = MON),
            payable("INV-9", 100, nothing),
            payable("INV-10", 100, MON + Day(60))]), Scenario(days = 2))
    @test closing(f) == [100_000_00, 100_000_00]
    @test reasons(f) == [:currency, :noinvoice, :nodue, :beyond]
end

@testset "the floor" begin
    f = forecast(snap(position = 1_000_00, items = [payable("INV-1", 120_000, MON + Day(1))]),
                 Scenario(days = 3, floor = 500_00))
    @test breach(f).day == MON + Day(1)
    @test lowest(f).closing == -200_00
    out = sprint(report, f)
    @test occursin("Under the floor of 500.00 from Tue 06 Oct", out)
    @test occursin("Lowest: -200.00 on Tue 06 Oct", out)
end

# The demo week on its Monday the 12th morning: 45,000.00 in the account,
# INV-E due the Saturday before, and the customer's 42,500.00 due on Tuesday.
const MON12 = Date(2026, 10, 12)
week(; kw...) = snap(; now = DateTime(MON12) + Hour(9), today = MON12, position = 45_000_00, kw...)
held(plan) = [(h.reference, h.from, h.to, h.days) for h in plan.holds]

@testset "a forecast that keeps the floor holds nothing" begin
    world = snap(items = [payable("INV-1", 120_000, MON)])
    plan = planpayments(world, Scenario(days = 3, floor = 50_000_00))
    @test plan.holds == []
    @test closing(plan.forecast) == closing(forecast(world, Scenario(days = 3)))
    @test shortfall(plan) === nothing
end

@testset "an invoice is held one day, until the customer has paid" begin
    world = week(items = [payable("INV-E", 61_450_00, Date(2026, 10, 10)),
                          receivable("1800000001", 42_500_00, Date(2026, 10, 13))])
    scenario = Scenario(days = 3, floor = 10_000_00)
    @test closing(forecast(world, scenario)) == [-16_450_00, 26_050_00, 26_050_00]
    plan = planpayments(world, scenario)
    @test held(plan) == [("INV-E", MON12, Date(2026, 10, 13), 1)]
    @test plan.holds[1].due == Date(2026, 10, 10)
    @test closing(plan.forecast) == [45_000_00, 26_050_00, 26_050_00]
    @test lowest(plan.forecast).day == Date(2026, 10, 13)
    @test closing(plan.before) == [-16_450_00, 26_050_00, 26_050_00]
    @test shortfall(plan) === nothing
    @test only(f for f in plan.forecast.flows if f.reference == "INV-E").note == "held from 2026-10-12"
end

@testset "of two invoices, the one that costs least to hold" begin
    # Either alone clears the floor on Monday; the small one is the one to hold.
    world = week(items = [payable("INV-BIG", 40_000_00, MON12), payable("INV-SMALL", 36_000_00, MON12),
                          receivable("1800000001", 42_500_00, Date(2026, 10, 13))])
    plan = planpayments(world, Scenario(days = 3, floor = 0))
    @test held(plan) == [("INV-SMALL", MON12, Date(2026, 10, 13), 1)]
    @test closing(plan.forecast) == [5_000_00, 11_500_00, 11_500_00]

    # Holding the small one is not enough here, so the large one is held.
    plan = planpayments(world, Scenario(days = 3, floor = 6_000_00))
    @test held(plan) == [("INV-BIG", MON12, Date(2026, 10, 13), 1)]
    @test closing(plan.forecast) == [9_000_00, 11_500_00, 11_500_00]
end

@testset "a tie goes to the invoice due latest, then by reference" begin
    money_in = receivable("1800000001", 42_500_00, Date(2026, 10, 13))
    world = week(items = [payable("INV-OLD", 30_000_00, Date(2026, 10, 9)),
                          payable("INV-NEW", 30_000_00, MON12), money_in])
    @test held(planpayments(world, Scenario(days = 3, floor = 0))) ==
          [("INV-NEW", MON12, Date(2026, 10, 13), 1)]
    for items in ([payable("INV-B", 30_000_00, MON12), payable("INV-A", 30_000_00, MON12), money_in],
                  [payable("INV-A", 30_000_00, MON12), money_in, payable("INV-B", 30_000_00, MON12)])
        @test held(planpayments(week(; items), Scenario(days = 3, floor = 0))) ==
              [("INV-A", MON12, Date(2026, 10, 13), 1)]
    end
end

@testset "a floor no plan can keep: the smallest shortfall, and the day" begin
    # Nothing comes in, so holding only moves the overdraft to the last day.
    world = week(items = [payable("INV-E", 61_450_00, Date(2026, 10, 10))])
    plan = planpayments(world, Scenario(days = 3, floor = 10_000_00))
    @test held(plan) == [("INV-E", MON12, Date(2026, 10, 14), 2)]
    @test closing(plan.forecast) == [45_000_00, 45_000_00, -16_450_00]
    @test shortfall(plan).day == Date(2026, 10, 14)
    @test shortfall(plan).closing == -16_450_00

    # A day that cannot be saved does not excuse one that can.
    world = week(position = 5_000_00,
                 items = [payable("INV-1", 20_000_00, Date(2026, 10, 13)),
                          receivable("1800000001", 30_000_00, Date(2026, 10, 14))])
    plan = planpayments(world, Scenario(days = 4, floor = 10_000_00))
    @test held(plan) == [("INV-1", Date(2026, 10, 13), Date(2026, 10, 14), 1)]
    @test closing(plan.forecast) == [5_000_00, 5_000_00, 15_000_00, 15_000_00]
    @test shortfall(plan).day == MON12
end

@testset "the schedule moves only what a run would pay, and never earlier" begin
    world = week(items = [payable("INV-E", 61_450_00, Date(2026, 10, 10)),
                          payable("INV-BLOCKED", 5_000_00, MON12; block = "A"),
                          payable("INV-USD", 5_000_00, MON12; currency = "USD"),
                          payable("INV-SENT", 20_000_00, MON12),
                          payable("INV-LATER", 1_000_00, Date(2026, 10, 14)),
                          receivable("1800000001", 42_500_00, Date(2026, 10, 13))],
                 payments = [BankPayment(reference = "INV-SENT", amount = 20_000_00, currency = "EUR",
                                         status = "accepted", settles = MON12)])
    plan = planpayments(world, Scenario(days = 3, floor = 0))
    @test held(plan) == [("INV-E", MON12, Date(2026, 10, 13), 1)]
    @test closing(plan.forecast) == [25_000_00, 6_050_00, 5_050_00]
    @test reasons(plan.forecast) == reasons(plan.before)
end

@testset "the schedule's own block is an outflow on the day it lets go, not money left out" begin
    items = [payable("INV-E", 61_450_00, Date(2026, 10, 10); block = "T", invoice = "5105600001/2026"),
             payable("INV-C", 50_00, MON12; block = "A", invoice = "5105600002/2026"),
             receivable("1800000001", 42_500_00, Date(2026, 10, 13))]
    scenario = Scenario(days = 3, floor = 10_000_00)
    f = forecast(week(; items), scenario)
    @test closing(f) == [45_000_00, 26_050_00, 26_050_00]
    @test reasons(f) == [:blocked]
    @test only(x for x in f.flows if x.reference == "INV-E").day == Date(2026, 10, 13)
    # With nothing to wait for, it goes on the day a run would pay it.
    f = forecast(week(; position = 100_000_00, items), scenario)
    @test closing(f) == [38_550_00, 81_050_00, 81_050_00]
    # Under another code it is somebody else's block.
    @test reasons(forecast(week(; items), Scenario(days = 3, holdcode = "Z"))) == [:blocked, :blocked]
end

@testset "what SAP has to be told: blocks to set, the schedule's own to lift, nobody else's" begin
    told(world, scenario) = [(c.action, c.reference, c.until, c.outcome)
                             for c in changes(world, planpayments(world, scenario))]
    money_in = receivable("1800000001", 42_500_00, Date(2026, 10, 13))
    scenario = Scenario(days = 3, floor = 10_000_00)
    tuesday = Date(2026, 10, 13)
    inv(block) = payable("INV-E", 61_450_00, Date(2026, 10, 10); block, invoice = "5105600001/2026")
    other = payable("INV-C", 50_00, MON12; block = "A", invoice = "5105600002/2026")
    @test told(week(items = [inv(""), other, money_in]), scenario) == [(:block, "INV-E", tuesday, :wanted)]
    @test told(week(items = [inv("T"), other, money_in]), scenario) == [(:block, "INV-E", tuesday, :already)]
    # On the day, or once there is money enough, the block is lifted.
    @test told(week(today = tuesday, now = DateTime(tuesday) + Hour(9), items = [inv("T"), other],
                    position = 87_500_00), scenario) == [(:release, "INV-E", nothing, :wanted)]
    @test told(week(position = 100_000_00, items = [inv("T"), other, money_in]), scenario) ==
          [(:release, "INV-E", nothing, :wanted)]
    @test told(week(position = 100_000_00, items = [inv(""), other, money_in]), scenario) == []
end

@testset "a receivable past its due date is still expected, inside the lateness assumed" begin
    items = [receivable("1800000001", 42_500_00, Date(2026, 10, 9))]       # the Friday before
    @test reasons(forecast(week(; items), Scenario(days = 2))) == [:overdue]
    late = forecast(week(; items), Scenario(days = 2, customerslate = 1))
    @test closing(late) == [87_500_00, 87_500_00]
    @test only(late.flows).note == "due 2026-10-09, assumed late"
    # A day after that it is overdue again: it did not come when it was expected.
    tuesday = Date(2026, 10, 13)
    @test reasons(forecast(week(; today = tuesday, now = DateTime(tuesday) + Hour(9), items),
                           Scenario(days = 2, customerslate = 1))) == [:overdue]
end

@testset "a plan that keeps the floor when customers pay late" begin
    world = week(items = [payable("INV-E", 61_450_00, Date(2026, 10, 10)),
                          receivable("1800000001", 42_500_00, Date(2026, 10, 13))])
    plan(upto; days = 4, late = 0) = planpayments(world, Scenario(; days, floor = 10_000_00,
                                                  customerslate = late, customerslateupto = upto))
    wednesday, thursday = Date(2026, 10, 14), Date(2026, 10, 15)

    # With no range, or one that is no range, it is the plan as it was.
    @test held(plan(0)) == [("INV-E", MON12, Date(2026, 10, 13), 1)]
    @test length(plan(0).cases) == 1
    @test held(plan(1; late = 1)) == held(plan(0; late = 1)) == [("INV-E", MON12, wednesday, 2)]

    # A day late, the money is there on Wednesday, so that is when the invoice goes:
    # the same hold in both cases, and the floor kept in both.
    cautious = plan(1)
    @test held(cautious) == [("INV-E", MON12, wednesday, 2)]
    @test [c.scenario.customerslate for c in cautious.cases] == [0, 1]
    @test closing(cautious.forecast) == closing(cautious.cases[1]) == [45_000_00, 87_500_00, 26_050_00, 26_050_00]
    @test closing(cautious.cases[2]) == [45_000_00, 45_000_00, 26_050_00, 26_050_00]
    @test shortfall(cautious) === nothing
    # The plan that trusts the due date is under the floor if the customer is late.
    paid_tuesday = Dict(h.document => h.to for h in plan(0).holds)
    @test closing(first(AcmeTreasury.project(world, Scenario(days = 4, customerslate = 1), paid_tuesday))) ==
          [45_000_00, -16_450_00, 26_050_00, 26_050_00]

    # A wider range never holds less.
    @test held(plan(2)) == [("INV-E", MON12, thursday, 3)]
    @test [helddays(plan(upto)) for upto in 0:2] == [1, 2, 3]

    # A case no plan can keep is held to the best it can be, and named.
    short = plan(2; days = 3)                       # two days late is after the last day
    @test held(short) == [("INV-E", MON12, wednesday, 2)]
    @test worstcase(short).scenario.customerslate == 2
    @test (shortfall(short).day, shortfall(short).closing) == (wednesday, -16_450_00)
    @test all(f -> breach(f) === nothing, short.cases[1:2])
end

# Two customers owing money in the week, and one invoice that needs both.
@testset "some customers late, each on their own" begin
    ann, bob = "1000006", "1000003"
    owes(number, party, amount, due) = OpenItem(; kind = :receivable, document = "1710/2026/" * number,
                                                number, party, amount, currency = "EUR", due)
    tuesday, wednesday, thursday = Date(2026, 10, 13), Date(2026, 10, 14), Date(2026, 10, 15)
    world = week(position = 20_000_00,
                 items = [payable("INV-1", 30_000_00, tuesday), payable("INV-2", 25_000_00, tuesday),
                          owes("1800000001", ann, 30_000_00, tuesday),
                          owes("1800000002", bob, 20_000_00, tuesday)])
    plan(some; upto = 1, days = 4, floor = 5_000_00) =
        planpayments(world, Scenario(; days, floor, customerslateupto = upto, latecustomers = some))

    # The two ends are the plans there already are.
    trusting = planpayments(world, Scenario(days = 4, floor = 5_000_00))
    together = planpayments(world, Scenario(days = 4, floor = 5_000_00, customerslateupto = 1))
    @test held(trusting) == []
    @test held(plan(0)) == held(trusting)
    @test held(plan(2)) == held(plan(5)) == held(together) ==
          [("INV-1", tuesday, wednesday, 1), ("INV-2", tuesday, wednesday, 1)]

    # One of them late: Bob's 20,000.00 alone would do no harm, Ann's 30,000.00
    # would, so the plan is for Ann, and holds only the invoice it has to.
    one = plan(1)
    @test held(one) == [("INV-2", tuesday, wednesday, 1)]
    @test one.late == Dict(ann => 1)
    @test closing(one.forecast) == [20_000_00, 40_000_00, 15_000_00, 15_000_00]
    @test closing(worstcase(one)) == [20_000_00, 10_000_00, 15_000_00, 15_000_00]
    @test shortfall(one) === nothing
    @test [helddays(plan(some)) for some in 0:2] == [0, 1, 2]       # more late never holds less
    @test helddays(plan(1; upto = 2)) >= helddays(one)              # nor does later

    # The worst case is the true one: every set of at most `some` customers,
    # each as late as the range allows, forecast by the forecast's own arithmetic.
    for some in 0:2, upto in 1:2
        made = plan(some; upto)
        planned = Dict(h.document => h.to for h in made.holds)
        lowest_of(own) = minimum(closing(first(AcmeTreasury.project(world, Scenario(days = 4), planned, own))))
        every = [Dict{String,Int}(zip(set, late)) for set in ([], [ann], [bob], [ann, bob])
                 if length(set) <= some for late in Iterators.product(fill(0:upto, length(set))...)]
        @test minimum(lowest_of, every) == lowest(worstcase(made)).closing
        @test minimum(lowest_of, every) >= 5_000_00
    end

    # A customer whose invoice is already past due, and still expected, is late
    # for certain: not one of the number, and counted beside them.
    already = week(position = 20_000_00,
                   items = [payable("INV-1", 30_000_00, tuesday), payable("INV-2", 25_000_00, tuesday),
                            owes("1800000001", ann, 30_000_00, tuesday),
                            owes("1800000002", bob, 20_000_00, tuesday),
                            owes("1800000003", bob, 1_000_00, Date(2026, 10, 9))])
    sure = planpayments(already, Scenario(days = 4, floor = 5_000_00, customerslateupto = 1, latecustomers = 1))
    # With Bob's money sure to be late and Ann's the one that may be, Tuesday
    # has neither, and both invoices wait: the same world held one above.
    @test held(sure) == [("INV-1", tuesday, wednesday, 1), ("INV-2", tuesday, wednesday, 1)]
    @test shortfall(sure) === nothing
end

@testset "a payment is an invoice's by more than its number" begin
    sent(; kw...) = BankPayment(; reference = "INV-100", amount = 1_000_00, currency = "EUR",
                                status = "accepted", settles = MON12, booked = true, kw...)
    inv(; amount = 1_000_00, kw...) = payable("INV-100", amount, MON12; invoice = "INV-100/2026", kw...)
    f(item, payment) = forecast(week(items = [item], payments = [payment]), Scenario(days = 1))
    # The same number, amount and a payment not older than the invoice: one outflow, already made.
    @test closing(f(inv(posted = Date(2026, 10, 1)), sent(received = Date(2026, 10, 9)))) == [45_000_00]
    # Another supplier's invoice with the same number, or the number used again: still owed.
    # An old payment is for an old invoice.
    @test closing(f(inv(amount = 2_500_00), sent())) == [42_500_00]
    @test closing(f(inv(posted = Date(2026, 10, 10)), sent(received = Date(2026, 9, 1)))) == [44_000_00]
end

@testset "an item a payment run has claimed is in payment" begin
    claimed(; kw...) = payable("INV-200", 10_000_00, Date(2026, 10, 14); invoice = "INV-200/2026",
                               run = "R1", rundate = MON12, kw...)
    # SAP says a run has it and the bank lists nothing for it yet: it goes out
    # on the run's day, not on its due date.
    f = forecast(week(items = [claimed()]), Scenario(days = 3))
    @test closing(f) == [35_000_00, 35_000_00, 35_000_00]
    @test only(f.flows).note == "in payment run R1 of 2026-10-12"
    # A run that sent it last week: today.
    @test closing(forecast(week(items = [claimed(rundate = Date(2026, 10, 9))]), Scenario(days = 1))) ==
          [35_000_00]
    # No plan may hold it, however low the floor goes, and nothing is wanted in SAP for it.
    plan = planpayments(week(items = [claimed()]), Scenario(days = 3, floor = 40_000_00))
    @test isempty(plan.holds)
    @test shortfall(plan).day == MON12
    @test isempty(changes(week(items = [claimed()]), plan))

    # Two invoices with the same number and amount, both posted before the
    # first was paid: the payment at the bank is the claimed one's, and the
    # other is still owed. Without a claim on either, nothing tells them apart.
    sent = BankPayment(; reference = "INV-100", amount = 1_000_00, currency = "EUR",
                       status = "accepted", settles = MON12, booked = true, received = MON12)
    twin(document, posted; kw...) = OpenItem(; kind = :payable, document, number = "INV-100",
                                             party = "1000013", amount = 1_000_00, currency = "EUR",
                                             due = MON12, reference = "INV-100", invoice = "INV-100/2026",
                                             posted, kw...)
    first = twin("1710/2026/1", Date(2026, 10, 1); run = "R1", rundate = MON12)
    second = twin("1710/2026/2", Date(2026, 10, 2))
    @test closing(forecast(week(items = [first, second], payments = [sent]), Scenario(days = 1))) == [44_000_00]
    @test closing(forecast(week(items = [second, first], payments = [sent]), Scenario(days = 1))) == [44_000_00]
    # Without a claim on either, nothing says which was paid. One of them was,
    # and one is still owed: the balance is right whichever name it carries.
    @test closing(forecast(week(items = [twin("1710/2026/1", Date(2026, 10, 1)), second],
                                payments = [sent]), Scenario(days = 1))) == [44_000_00]
    # The first was settled by the statement and is open no longer. The payment
    # is still its, and the second is still owed: a payment is one item's.
    settled = twin("1710/2026/1", Date(2026, 10, 1); cleared = MON12)
    @test closing(forecast(week(items = [second], cleared = [settled], payments = [sent]),
                           Scenario(days = 1))) == [44_000_00]
    # A payment the bank took in after the item was settled did not settle it.
    earlier = twin("1710/2026/1", Date(2026, 10, 1); cleared = Date(2026, 10, 9))
    @test closing(forecast(week(items = [second], cleared = [earlier], payments = [sent]),
                           Scenario(days = 1))) == [45_000_00]
    # Two payments, one each: the settled item takes the one that settled it.
    again = BankPayment(; reference = "INV-100", amount = 1_000_00, currency = "EUR",
                        status = "accepted", settles = MON12, booked = false, received = MON12)
    @test closing(forecast(week(items = [second], cleared = [settled], payments = [again, sent]),
                           Scenario(days = 1))) == [44_000_00]
end
