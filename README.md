# mock-treasury

[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**A cash forecast you can check.** It reads what
[mock-sap](https://github.com/rseufert/mock-sap) says is owed and what
[mock-bank](https://github.com/rseufert/mock-bank) says it holds, and says
what the account will close at on each of the next business days. Then the
clocks are moved, the payment run runs, and the bank's statements say whether
it was right.

```
mock-sap   ──open items──────────────▶
                                        mock-treasury  ──▶  closing balance, day by day
mock-bank  ──camt.052, payments,─────▶
             credits, clock, holidays

                        ... a week of mornings and nights ...

mock-bank  ──camt.053──▶  the same figure, or the test fails
```

Most cash forecasts are never held to anything: by the time the day arrives
nobody looks back. Both mocks keep a clock a test can move, so here Monday's
forecast for the following Monday is compared, to the cent, with the statement
the bank issues for it.

Written in Julia. Unlike the mocks it takes dependencies:
[HTTP.jl](https://github.com/JuliaWeb/HTTP.jl),
[JSON.jl](https://github.com/JuliaIO/JSON.jl),
[EzXML.jl](https://github.com/JuliaIO/EzXML.jl) and
[UnicodePlots.jl](https://github.com/JuliaPlots/UnicodePlots.jl).

MIT licensed. By [Rick Seufert](https://rickseufert.com).

---

## Quick start

It needs Julia 1.13 and, to have something to forecast, the two mocks and
[mock-acme](https://github.com/rseufert/mock-acme), whose payment run the demo's setup and the tests use:

```bash
pip install mock-sap mock-bank git+https://github.com/rseufert/mock-acme
julia --project=. -e 'using Pkg; Pkg.instantiate()'
bin/demo
```

`bin/demo` starts both mocks on a Monday morning, posts a week's invoices and
a customer's payment, and forecasts it:

```
ACME  EUR  as of 2026-10-05 09:00, before the cutoff
Booked balance now       125,000.00

day                 opening              in             out         closing
Mon 05 Oct       125,000.00            0.00       -1,200.00      123,800.00
Tue 06 Oct       123,800.00        2,000.00            0.00      125,800.00
Wed 07 Oct       125,800.00            0.00      -80,800.00       45,000.00
Thu 08 Oct        45,000.00            0.00            0.00       45,000.00
Fri 09 Oct        45,000.00            0.00            0.00       45,000.00
Mon 12 Oct        45,000.00            0.00      -61,450.00      -16,450.00  <
Tue 13 Oct       -16,450.00       42,500.00            0.00       26,050.00
Wed 14 Oct        26,050.00            0.00            0.00       26,050.00

Lowest: -16,450.00 on Mon 12 Oct
Under the floor of 10,000.00 from Mon 12 Oct

What moves it
  Mon 05 Oct        -1,200.00  payable     INV-A             1000013
  Tue 06 Oct         2,000.00  credit                        Customer Ltd   PAYMENT
  Wed 07 Oct       -80,800.00  payable     INV-B             1000016
  Mon 12 Oct       -61,450.00  payable     INV-E             1000016
  Tue 13 Oct        42,500.00  receivable  0100000011        1000006

Left out
  blocked              -50.00  INV-C             1000013       payment block A
  overdue           29,496.20  0100000001        1000006       due 2025-10-12
  ...
```

An invoice due on Saturday the 10th is paid on Monday the 12th, a day before
the customer's money arrives, and the account is overdrawn for one night.

Against mocks that are already running:

```bash
bin/mock-treasury --sap http://127.0.0.1:8000 --bank http://127.0.0.1:8080
```

| Flag | Default | What it does |
| --- | --- | --- |
| `--sap` | `$SAP_URL`, or `http://127.0.0.1:8000` | mock-sap |
| `--bank` | `$BANK_URL`, or `http://127.0.0.1:8080` | mock-bank |
| `--account` | `ACME` | The account at the bank |
| `--days` | `10` | Business days to look ahead |
| `--customers-late` | `0` | Assume every customer pays this many business days late |
| `--release-blocked` | off | Assume every payment block is lifted |
| `--floor` | `0.00` | Flag a closing balance under this |
| `--plot` | off | Draw the closing balances in the terminal |
| `--json` | off | The forecast as JSON, amounts in minor units |

The exit status is `0`, `1` when a closing balance is under the floor, and `2`
when either side could not be read, so it can stand in a pipeline.

## What it reads

| From | What | How |
| --- | --- | --- |
| mock-bank | The booked balance now | An intraday `camt.052`, asked for on the spot. Opening plus entries must be the interim balance, or it is not believed |
| mock-bank | Payments accepted and not yet settled, and settled payments due to come back | `GET /_mock/payments` |
| mock-bank | Money on its way in | `GET /_mock/credits` |
| mock-bank | Today, the cutoff, the holidays | `GET /_mock/state` |
| mock-sap | Open supplier and customer items, with due dates and blocks | `API_OPLACCTGDOCITEMCUBE_SRV` |
| mock-sap | The invoice number each payable's payment carries | `API_SUPPLIERINVOICE_PROCESS_SRV` |

The `camt.052` and the two OData services are what a real bank and a real
S/4HANA system offer. The three `/_mock` reads are not: a real bank does not
tell you a payment will be returned on Thursday. That is the mock's control
plane, and what comes from it is labelled `payment`, `credit` or `return` in
the output, apart from what SAP said.

Asking for the `camt.052` leaves one message in the bank's mailbox each time.

## What it holds to

Each of these is a way a cash forecast is quietly wrong.

- **A payment at the bank is not owed twice.** SAP keeps an item open until a
  statement clears it, so on the morning after a payment run the same invoice
  is an open item in SAP and a debit at the bank. They are joined on the
  `EndToEndId` and counted once.
- **A blocked item is not money going out.** It is listed with its block, and
  `--release-blocked` says what lifting them all would do.
- **An overdue receivable is not money coming in.** It was due once already.
  mock-sap seeds six of them, 684,875.06 EUR in all, and a forecast that
  believed them would be comfortable and wrong.
- **A payment the bank refused will be refused again.** Its item stays open in
  SAP and every run selects it again; it is listed with the bank's reason.
- **A payment that will come back comes back, and is owed again:** the credit
  on the day of the return, and the payment once more on the next run.
- **A credit the bank already holds replaces the receivable it names**, when
  the payer's reference or note carries the accounting document number. A
  payer who quotes nothing is counted beside the receivable, because nothing
  says they are the same money.
- **After the cutoff, today's run settles tomorrow,** and nothing settles on a
  weekend or a holiday on the bank's list.
- **Another currency is not added up.** mock-bank does no FX and neither does
  this; an item in a currency the account is not in is listed.

It assumes a payment run every business morning, which pays each supplier item
on its due date. That is what `payment_run` in
[mock-acme](https://github.com/rseufert/mock-acme) does.

## What it cannot know

A forecast taken on Monday morning expects to pay an invoice whose supplier
closed their account last week. The bank refuses it with `AC04`, the money
stays, and Monday's forecast was out by that invoice. Tuesday's lists it under
the bank's reason. `test/mocks.jl` holds both halves, because a forecast that
is checked has to say where it will be wrong.

The same goes for a customer who pays late, short or not at all, and for a
return the bank has not been told to make yet. `--customers-late` is an
assumption, not a prediction: both mocks are deterministic on purpose, so
there is no history here to fit a probability to.

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

`test/units.jl` holds each rule above against a snapshot written by hand; the
forecast is a pure function of one, so these need nothing running.

`test/mocks.jl` starts both mocks on a pinned clock and plays time forward.
The run each morning is mock-acme's `payment_run`, unchanged, so the forecast
is held to the reference integration and not to a chain written to agree with
it.

| Test | What it proves |
| --- | --- |
| A week, forecast on Monday and every morning after | Eight forecasts, one each morning, and every closing balance in each of them is the closing balance of the `camt.053` for that day: a payable due on a Saturday, a blocked one, a credit that names nothing and a customer who pays on the due date and quotes the document |
| A return is forecast once the bank knows of it | Under `return-later`, Tuesday's forecast has the money back on Thursday and gone again on Friday, and the statements agree |
| What Monday cannot know | The closed account above: Monday is out by the invoice, Tuesday is not |
| A side that is down is named | SAP or the bank not answering is said in words, with exit status 2 |

They need a Python with both mocks and mock-acme installed, as in the quick
start: `MOCK_PYTHON`, or `python3`.
Without one they are skipped with a warning and the unit tests still run.

## Layout

| File | What is in it |
| --- | --- |
| `src/forecast.jl` | The forecast: a pure function of a snapshot and a scenario |
| `src/snapshot.jl` | What a snapshot is: open items, payments, credits, the balance, the day |
| `src/wire.jl` | Reading both mocks over HTTP |
| `src/calendar.jl`, `src/money.jl` | Business days, and amounts as whole minor units |
| `src/report.jl`, `src/cli.jl` | The table, the plot, the JSON and the command line |
| `test/world.py` | The suppliers, the customers and the morning's payment run |

## Out of scope

| Left out | Why |
| --- | --- |
| Probabilities | Nothing in two deterministic mocks to fit them to. Scenarios are stated assumptions |
| FX and more than one account | One account, one currency, as mock-bank's accounts are |
| Direct debits and NACHA | The payment run this follows pays by `pain.001` credit transfer |
| Clearing customer items in SAP | Nothing in the chain does it yet, so a paid receivable stays open there and is recognised by the credit that names it |

## See also

[mock-sap](https://github.com/rseufert/mock-sap),
[mock-edi](https://github.com/rseufert/mock-edi) and
[mock-bank](https://github.com/rseufert/mock-bank),
[mock-acme](https://github.com/rseufert/mock-acme), the integration between
them, and [rickseufert.com](https://rickseufert.com/#projects) for the worked examples
that use them together.
