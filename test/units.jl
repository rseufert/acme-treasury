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
