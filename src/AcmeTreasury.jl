"""
A cash forecast for one bank account, made from what mock-sap says is owed and
what mock-bank says it holds - and checked against the statements the bank
then issues.
"""
module AcmeTreasury

using Dates
using EzXML: parsexml, root, nodecontent, nodename, eachelement
using HiGHS
using HTTP
using JSON
using JuMP
using UnicodePlots: stairs

export cents, money, BankCalendar, isbusinessday, onorafter, addbusinessdays,
       OpenItem, BankPayment, BankCredit, Snapshot, Scenario, Flow, Aside, DayLine,
       Forecast, forecast, snapshot, lowest, breach, Hold, Plan, planpayments, shortfall, Change, changes, apply,
       report, asjson, main

include("money.jl")
include("calendar.jl")
include("snapshot.jl")
include("forecast.jl")
include("schedule.jl")
include("wire.jl")
include("apply.jl")
include("report.jl")
include("cli.jl")

end
