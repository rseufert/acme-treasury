const USAGE = """
usage: mock-treasury [--sap URL] [--bank URL] [--account ID] [--days N]
                     [--customers-late N] [--release-blocked] [--floor AMOUNT]
                     [--plot] [--json]

Forecast a bank account's closing balance from what mock-sap says is owed and
what mock-bank says it holds.

  --sap URL            mock-sap (default: \$SAP_URL or http://127.0.0.1:8000)
  --bank URL           mock-bank (default: \$BANK_URL or http://127.0.0.1:8080)
  --account ID         the account at the bank (default: ACME)
  --days N             business days to look ahead (default: 10)
  --customers-late N   assume every customer pays N business days late
  --release-blocked    assume every payment block is lifted
  --floor AMOUNT       flag a closing balance under this (default: 0.00)
  --plot               draw the closing balances
  --json               print the forecast as JSON, amounts in minor units

Exit status is 0, 1 when a closing balance is under the floor, and 2 when
either side could not be read.
"""

function main(args::Vector{String} = ARGS)::Int
    sap = get(ENV, "SAP_URL", "http://127.0.0.1:8000")
    bank = get(ENV, "BANK_URL", "http://127.0.0.1:8080")
    account, days, late, release, floor, plot, json = "ACME", 10, 0, false, 0, false, false
    args = copy(args)
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
            elseif flag == "--plot"
                plot = true
            elseif flag == "--json"
                json = true
            else
                throw(ArgumentError("unknown argument $flag"))
            end
        end
    catch error
        error isa ArgumentError || rethrow()
        println(stderr, "mock-treasury: ", error.msg, "\n\n", USAGE)
        return 2
    end
    result = try
        forecast(snapshot(String(rstrip(sap, '/')), String(rstrip(bank, '/')), account),
                 Scenario(; days, customerslate = late, releaseblocked = release, floor))
    catch error
        error isa Unusable || rethrow()
        println(stderr, "mock-treasury: ", error.message)
        return 2
    end
    json ? println(asjson(result)) : report(stdout, result; plot)
    breach(result) === nothing ? 0 : 1
end
