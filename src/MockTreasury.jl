"""
A cash forecast for one bank account, made from what mock-sap says is owed and
what mock-bank says it holds - and checked against the statements the bank
then issues.
"""
module MockTreasury

using Dates
using EzXML: parsexml, root, nodecontent, nodename, eachelement
using HTTP
using JSON
using UnicodePlots: stairs

export cents, money, BankCalendar, isbusinessday, onorafter, addbusinessdays,
       OpenItem, BankPayment, BankCredit, Snapshot, Scenario, Flow, Aside, DayLine,
       Forecast, forecast, snapshot, lowest, breach, report, asjson, main

include("money.jl")
include("calendar.jl")
include("snapshot.jl")
include("forecast.jl")
include("wire.jl")
include("report.jl")
include("cli.jl")

end
