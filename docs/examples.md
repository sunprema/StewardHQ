# Example Scenarios

A few concrete situations StewardHQ is built for — each one maps directly onto the mechanisms described in the [README](../README.md) and [`tech_spec.md`](tech_spec.md), not a hypothetical.

## Paying an invoice

An agent decides an invoice is ready to be paid and calls the `pay` action. Before anything reaches the real payment API, the agent has to actually hold an exclusive borrow on that invoice and a `:pay` capability — a right that's consumed the instant it's exercised, so the same invoice can't be paid twice by two agents racing each other, or by the same agent retrying after a timeout it misread as a failure. The write itself carries a lease and a fencing token, so if the invoice was already paid by something else in the meantime, the backend rejects the write outright instead of silently double-charging. If the payment call times out with an ambiguous outcome, the repair loop re-checks the real backend until it knows what actually happened, rather than guessing and either dropping a real payment or recording a phantom one.

## Cancelling an order

Cancelling an order isn't one action — it's a plan: refund the payment, restock the inventory, and notify the customer. The plan validator checks this plan before any of it runs, and rejects it outright if the customer-notification email (irreversible — it can't be unsent) was scheduled before the refund (which might still fail). If the refund step fails partway through, the saga unwinds what already succeeded — putting the inventory back on hold, say — instead of leaving the order in a half-cancelled state that a human has to untangle later.

## A supervisor delegating approval to a specialist sub-agent

A general-purpose agent handling an expense report spawns a narrower, specialized sub-agent just to decide whether a specific expense should be approved, and hands it the `:approve` capability to act on. That capability is moved, not copied — the supervisor's own copy stops working the instant the hand-off happens, so there's no way for both the supervisor and the sub-agent to end up approving the same expense independently. If the sub-agent crashes before finishing, the capability is released automatically; it doesn't sit around waiting to be cleaned up by hand, and it can't be picked up again by some other unrelated process later.
