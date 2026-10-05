const USAGE = """
usage: acme-treasury [plan [--apply]] [--sap URL] [--bank URL] [--account ID]
                     [--days N] [--customers-late N] [--release-blocked]
                     [--floor AMOUNT] [--hold-code C] [--plot] [--json]

Forecast a bank account's closing balance from what mock-sap says is owed and
what mock-bank says it holds. With `plan`, say which invoices to hold so that
no day closes under the floor.

  plan                 print the payment schedule instead of the forecast
  --apply              with plan: set and lift payment blocks in SAP to match.
                       Without it nothing is written
  --sap URL            mock-sap (default: \$SAP_URL or http://127.0.0.1:8000)
  --bank URL           mock-bank (default: \$BANK_URL or http://127.0.0.1:8080)
  --account ID         the account at the bank (default: ACME)
  --days N             business days to look ahead (default: 10)
  --customers-late N   assume every customer pays N business days late
  --release-blocked    assume every payment block is lifted
  --floor AMOUNT       flag a closing balance under this (default: 0.00)
  --hold-code C        the payment block that is the schedule's own (default: T)
  --plot               draw the closing balances
  --json               print the forecast or the plan as JSON, amounts in minor units

Exit status is 0, 1 when a closing balance is under the floor (with plan: when
no plan keeps it), and 2 when either side could not be read or SAP refused a
write.
"""

function main(args::Vector{String} = ARGS)::Int
    sap = get(ENV, "SAP_URL", "http://127.0.0.1:8000")
    bank = get(ENV, "BANK_URL", "http://127.0.0.1:8080")
    account, days, late, release, floor, plot, json = "ACME", 10, 0, false, 0, false, false
    holdcode, writes = "T", false
    args = copy(args)
    planning = !isempty(args) && first(args) == "plan"
    planning && popfirst!(args)
    try
        while !isempty(args)
            flag = popfirst!(args)
            value() = isempty(args) ? throw(ArgumentError("$flag needs a value")) : popfirst!(args)
            if flag in ("-h", "--help")
                print(USAGE)
                return 0
            elseif flag == "--sap"
                sap = value()
            elseif flag == "--bank"
                bank = value()
            elseif flag == "--account"
                account = value()
            elseif flag == "--days"
                days = parse(Int, value())
                days >= 1 || throw(ArgumentError("--days is at least 1"))
            elseif flag == "--customers-late"
                late = parse(Int, value())
                late >= 0 || throw(ArgumentError("--customers-late is not negative"))
            elseif flag == "--release-blocked"
                release = true
            elseif flag == "--floor"
                floor = cents(value())
            elseif flag == "--hold-code"
                holdcode = value()
                length(holdcode) == 1 || throw(ArgumentError("--hold-code is one character"))
            elseif flag == "--apply" && planning
                writes = true
            elseif flag == "--plot" && !planning
                plot = true
            elseif flag == "--json"
                json = true
            else
                throw(ArgumentError("unknown argument $flag"))
            end
        end
    catch error
        error isa ArgumentError || rethrow()
        println(stderr, "acme-treasury: ", error.msg, "\n\n", USAGE)
        return 2
    end
    sap, bank = String(rstrip(sap, '/')), String(rstrip(bank, '/'))
    scenario = Scenario(; days, customerslate = late, releaseblocked = release, floor, holdcode)
    result, wanted = try
        snap = snapshot(sap, bank, account)
        if planning
            plan = planpayments(snap, scenario)
            wanted = changes(snap, plan)
            plan, writes ? apply(sap, wanted, holdcode) : wanted
        else
            forecast(snap, scenario), Change[]
        end
    catch error
        error isa Unusable || rethrow()
        println(stderr, "acme-treasury: ", error.message)
        return 2
    end
    try
        if planning
            json ? println(asjson(result, wanted; applied = writes)) :
                   report(stdout, result, wanted; applied = writes)
        else
            json ? println(asjson(result)) : report(stdout, result; plot)
        end
    catch error
        # Piped into `head`, which has read enough: not a failure.
        error isa Base.IOError || rethrow()
    end
    planning || return breach(result) === nothing ? 0 : 1
    any(c -> c.outcome == :refused, wanted) ? 2 : shortfall(result) === nothing ? 0 : 1
end
