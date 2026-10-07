# Changelog

Every tagged version of acme-treasury. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the versions
follow [semantic versioning](https://semver.org/spec/v2.0.0.html) - while the
major version is 0, a minor bump may change behaviour, and each entry says so
where it does. Nothing is published anywhere: a version is a tag on this
repository.

## [Unreleased]

### Added

- **A payment run's claim on an open item is read, and is SAP's word that the
  item is in payment** (#25). mock-sap 0.19.0 carries `PaymentRunID` and
  `PaymentRunDate` to the open item, and mock-acme 0.3.0's run writes them
  before its file goes. A claimed payable goes out on the run's day whether or
  not the bank's list has it, with `in payment run R1 of 2026-10-12` as its
  note, and no plan holds it. Where a payment at the bank fits two open items
  with the same number and amount, it is the claimed one's; the other is still
  owed. A mock-sap before 0.19.0 reads as before: no claim, and the bank's
  list decides.
- Tested against mock-sap 0.19.0, 0.20.0 and 0.21.0, mock-bank 0.9.0 and
  mock-acme 0.3.2 and 0.5.0. CI installs the mocks unpinned from PyPI. The README's figure for
  the seeded overdue receivables is 0.20.0's, 524,619.42 EUR, where it was
  0.19.0's 684,875.06.

### Fixed

- **A payment a statement has already settled in SAP was taken as another
  invoice's** (#29). Two suppliers number an invoice the same, for the same
  amount; the first is paid and its item settled by the next statement, and
  the second's open item was the only one left that fit the payment, so it
  was taken as paid, held by no plan, and paid by Wednesday's run under the
  floor. The forecast now reads the supplier items SAP settled in the last
  month beside the open ones, and decides the join once: each payment is one
  item's, a settled item first, then a claimed one, then one merely open.

## [0.3.0] - 2026-10-05

### Added

- **A plan for some customers late, not all of them at once** (#16).
  `--late-customers K`, with `--customers-late-up-to N`, keeps the floor
  whichever K customers are up to N business days late, each on their own.
  The output names the customers in the worst case, and says what the plan
  costs against trusting the due dates and against every customer late.
- Tests for `plan --apply` after the bank's cutoff.
- **A third film** (#17), `docs/films/treasury_late.gif`: a customer pays a
  day late, under the plan that trusted them and the plan that did not.
- `plan --json` has `cases`: each day's closing under the plan in every case
  it was held to.

### Fixed

- **A payment is an invoice's by more than its number.** The forecast joined
  an open item to a bank payment on the `EndToEndId` alone, so a second
  invoice with a number already paid was left out of the forecast as "at the
  bank". The payment must now also be for the item's amount and currency, and
  not older than the item.
- The tests' payment run keeps mock-acme's register in a file, so a run after
  the cutoff no longer pays an invoice twice. Two tests were marked broken for
  that, and it was this repository's helper, not mock-acme.

## [0.2.0] - 2026-10-05

### Added

- **A payment schedule** (#1). `planpayments(snapshot, scenario)` chooses which
  payables to hold, and until which business day, so that no day closes under
  the floor, at the least amount times business days held. It is a
  mixed-integer program in JuMP, solved by HiGHS. A floor no plan can keep is
  not an error: each day is held to the best closing any plan could give it,
  and `shortfall` names the worst.
- **`acme-treasury plan` and `plan --apply`** (#2). `plan` prints the schedule
  and writes nothing. `--apply` sets a payment block on each held invoice in
  SAP and lifts its own block, `--hold-code`, `T` by default, from each one it
  no longer holds. It never touches a block with another reason. This is the
  first write this repository makes to SAP.
- **The schedule is held to the bank's statements** (#3), as the forecast is:
  the demo week played against both mocks with and without it.
- **A plan that keeps the floor when customers pay late** (#11).
  `--customers-late-up-to N` holds one plan to the floor for every lateness
  from `--customers-late` to N, and says what the caution costs.
- **A second film** (#4), `docs/films/treasury_plan.gif`: the forecast under
  the floor, the plan, and eight statements on the planned line.
- **An index of the films** in `docs/films/index.json`, in the layout
  mock-films uses, with a `driven_by` for what else a capture ran.

### Changed

- **A receivable past its due date is still expected, inside the lateness
  assumed.** With `--customers-late 1`, an invoice due yesterday is expected
  today; before, anything due before today was overdue whatever was assumed.
  With no lateness assumed nothing changes.
- **An item under the schedule's own block is forecast, not left out:** it is
  an outflow on the day the schedule would let it go. Any other block is
  listed under "Left out" as before.
- The films moved from `docs/week.gif` to `docs/films/treasury_week.gif`.
- mock-acme is installed from PyPI.
- JuMP and HiGHS are dependencies.

## [0.1.0] - 2026-10-05

The cash forecast: a pure function of what mock-sap says is owed and what
mock-bank says it holds, checked against the `camt.053` statements the bank
then issues, with the first film. It was not tagged.

[0.3.0]: https://github.com/rseufert/acme-treasury/tree/v0.3.0
[0.2.0]: https://github.com/rseufert/acme-treasury/tree/v0.2.0
