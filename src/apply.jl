# A plan is a list of invoices and days, and nothing pays later because a list
# says so: a payment run selects every open supplier item that is due and not
# blocked. So a held invoice is blocked in SAP, as a user would block it, and
# the block is lifted on the morning the plan pays it. The plan is stored
# nowhere else: each morning it is made again, and SAP is brought to it.

"One payment block to set or lift, and what became of it."
struct Change
    action::Symbol              # :block :release
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
"""
function changes(snap::Snapshot, plan::Plan)::Vector{Change}
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
        elseif item.block == code
            change(:release, nothing, :wanted)
        end
    end
    sort!(found; by = c -> (c.action != :block, something(c.until, Date(0)), c.reference))
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
        refusal = setblock!(session, c.invoice, c.action == :block ? code : "")
        Change(c.action, c.invoice, c.reference, c.party, c.amount, c.until,
               refusal == "" ? :done : :refused, refusal)
    end
end
