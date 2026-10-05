# A plan is a list of invoices and days, and nothing pays later because a list
# says so: a payment run selects every open supplier item that is due and not
# blocked. So a held invoice is blocked in SAP, as a user would block it, and
# the block is lifted on the morning the plan pays it. The plan is stored
# nowhere else: each morning it is made again, and SAP is brought to it.

"One payment block to set or lift, and what became of it."
struct Change
    action::Symbol              # :block :guard :release
    invoice::String             # SupplierInvoice/FiscalYear
    reference::String
    party::String
    amount::Int
    until::Union{Date,Nothing}  # the day the plan pays a blocked one
    outcome::Symbol             # :wanted :already :done :refused
    message::String
end

"""
    changes(snapshot, plan)

What SAP has to be told for the plan to happen: a block on every invoice the
plan holds, and the schedule's own block lifted from every invoice it no
longer holds. A pure function; nothing is written.

- **Only the schedule's own block is ever lifted.** An invoice blocked with any
  other reason is blocked for a reason, and is not the schedule's to release
  or to hold.
- **What is already so is said, not done again:** a hold whose block is set
  comes back as `:already`.

With `guard`, an open invoice whose payment the bank has accepted and not sent
back is blocked too, as `:guard`. SAP keeps an item open until a statement
clears it, and a payment run that starts before that statement would select
it and pay it again. The statement then clears the item, block and all; if
the payment comes back instead, the item is no longer at the bank and the
block is lifted like any other the plan does not hold. It protects the run
that follows it and no other. It is for a payment program that keeps no
record of what it has sent: one that does, as mock-acme's register does,
leaves it nothing to do.
"""
function changes(snap::Snapshot, plan::Plan; guard::Bool = false)::Vector{Change}
    code = plan.forecast.scenario.holdcode
    holds = Dict(h.document => h for h in plan.holds)
    found = Change[]
    for item in snap.items
        (item.kind == :payable && item.invoice != "") || continue
        hold = get(holds, item.document, nothing)
        change(action, until, outcome) = push!(found, Change(
            action, item.invoice, item.reference, item.party, item.amount, until, outcome, ""))
        if hold !== nothing
            change(:block, hold.to, item.block == code ? :already : :wanted)
        elseif guard && atbank(paymentfor(snap, item))
            # Somebody else's block keeps a run off it as well as ours would.
            item.block in ("", code) && change(:guard, nothing, item.block == code ? :already : :wanted)
        elseif item.block == code
            change(:release, nothing, :wanted)
        end
    end
    order = Dict(:block => 1, :guard => 2, :release => 3)
    sort!(found; by = c -> (order[c.action], something(c.until, Date(0)), c.reference))
end

"""
    apply(sap, changes, code)

Write every change that is `:wanted`. One SAP refuses is `:refused`, with what
SAP said, and the rest are still written.
"""
function apply(sap::String, wanted::Vector{Change}, code::String)::Vector{Change}
    session = SapSession(sap)
    map(wanted) do c
        c.outcome == :wanted || return c
        refusal = setblock!(session, c.invoice, c.action == :release ? "" : code)
        Change(c.action, c.invoice, c.reference, c.party, c.amount, c.until,
               refusal == "" ? :done : :refused, refusal)
    end
end
