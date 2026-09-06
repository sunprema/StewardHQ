# Engineering Cookbook

Dev-only, runnable worked examples of StewardHQ acting as a resource gateway in front of three dummy backend APIs — `Steward.Cookbook.PaymentGateway` (stands in for a payment processor), `Steward.Cookbook.Warehouse` (stands in for an inventory/fulfillment system), and `Steward.Cookbook.StripeGateway` (makes real HTTP calls against [`stripe-mock`](https://github.com/stripe/stripe-mock), not the real Stripe API). All three simulate the real quirks (version conflicts, on-demand failures) that make the safety mechanisms in [`README.md`](../README.md) and [`docs/examples.md`](examples.md) worth having, rather than just asserting they work.

**Dev only, on purpose.** None of this is registered in `test` or `prod` config (see `config/dev.exs` and `Steward.Cookbook.PaymentGateway`'s moduledoc). The data lives in shared, in-memory ETS tables that reset every time you restart the app — don't expect anything you create here to survive a restart.

## Setup

```bash
mix setup            # installs deps, creates + migrates the dev database
iex -S mix phx.server
```

The saga/step audit trail (`Steward.Sagas.Saga`/`SagaStep`) is real Postgres state even though the cookbook's own resources aren't — that part of the machinery doesn't change based on what it's governing.

## Recipe 1: Paying an invoice through a real (simulated) payment gateway

```elixir
alias Steward.Cookbook
alias Steward.MCP.Facade
alias Hermes.Server.Frame

{:ok, frame} = Facade.init(%{}, Frame.new())

# Creating the invoice is itself a stewarded action, so it needs a real
# borrow: `Steward.witness/1` wraps the token the borrow hands you, and
# the borrow is released as soon as the function returns — well before the
# tool calls below acquire their own.
invoice =
  Steward.borrow({Cookbook.Invoice, :new}, :exclusive, fn token ->
    Cookbook.create_invoice!("acme-inv-1001", Ecto.UUID.generate(), Decimal.new(500),
      context: Steward.witness(token)
    )
  end)

{:reply, _approved, frame} =
  Facade.handle_tool_call("approve_invoice", %{"resource_id" => invoice.id}, frame)

{:reply, paid, _frame} =
  Facade.handle_tool_call("pay_invoice", %{"resource_id" => invoice.id, "amount_paid" => "500"}, frame)

paid.structured_content["status"]
#=> "paid"

Steward.Cookbook.PaymentGateway.fetch(invoice.external_id)
#=> {:ok, %{version: 1, state: %{amount_paid: Decimal.new("500")}}}
```

`Facade.handle_tool_call/3` is exactly what a real MCP client calling `pay_invoice` over `/mcp` triggers — this is calling the same tool dispatch directly, without needing an actual MCP client for the first pass. The `PaymentGateway.fetch/1` result at the end is the important part: that's the *simulated external system's own state*, and it only has an entry because `pay_invoice` genuinely called out to it — carrying a fencing token and a version check, not just flipping a local attribute.

### Try breaking it: two concurrent payments for the same invoice

```elixir
test_pid = self()

for _ <- 1..2 do
  spawn(fn ->
    result = Facade.handle_tool_call("pay_invoice", %{"resource_id" => invoice.id, "amount_paid" => "500"}, frame)
    send(test_pid, {:done, result})
  end)
end

for _ <- 1..2 do
  receive do
    {:done, {:reply, response, _frame}} -> {response.isError, response.structured_content}
  end
end
```

One call succeeds (`isError: false`, `status: "paid"`); the other comes back `isError: true` with `%{"reason" => "stale_resource"}`. Both requests raced for the same borrow — one queued behind the other — and by the time the second one actually reached the payment gateway, the version it expected was already gone. No double charge, and the loser gets told exactly why instead of a generic failure.

## Recipe 2: Cancelling an order — a plan that rolls back when a step fails

Cancelling an order is a three-step plan, not one action: refund the payment, restock the inventory, notify the customer. `notify` is irreversible (a sent email), so the plan validator would reject any plan that scheduled it before a step that might still fail — it's deliberately listed last.

```elixir
order =
  Steward.borrow({Cookbook.Order, :new}, :exclusive, fn token ->
    Cookbook.create_order!("acme-ord-2002", Ecto.UUID.generate(), "sku-42", 2, Decimal.new(80),
      context: Steward.witness(token)
    )
  end)

plan = [
  %{id: Ash.UUID.generate(), resource: Cookbook.Order, resource_id: order.id, action: :refund, observed_at: DateTime.utc_now()},
  %{id: Ash.UUID.generate(), resource: Cookbook.Order, resource_id: order.id, action: :restock, observed_at: DateTime.utc_now()},
  %{id: Ash.UUID.generate(), resource: Cookbook.Order, resource_id: order.id, action: :notify, observed_at: DateTime.utc_now()}
]

Steward.SagaExecutor.execute(plan)
#=> {:ok, :sent}
```

That's the happy path — refund and restock both went through the (simulated) warehouse/payment systems, then the notification fired last. Now force the warehouse to reject the restock and watch the saga unwind instead of leaving the order half-cancelled:

### Try breaking it: force the warehouse to reject the restock

```elixir
order =
  Steward.borrow({Cookbook.Order, :new}, :exclusive, fn token ->
    Cookbook.create_order!("acme-ord-2003", Ecto.UUID.generate(), "sku-42", 2, Decimal.new(80),
      context: Steward.witness(token)
    )
  end)

Steward.Cookbook.Warehouse.simulate_failure(order.external_id, :out_of_stock)

plan = [
  %{id: Ash.UUID.generate(), resource: Cookbook.Order, resource_id: order.id, action: :refund, observed_at: DateTime.utc_now()},
  %{id: Ash.UUID.generate(), resource: Cookbook.Order, resource_id: order.id, action: :restock, observed_at: DateTime.utc_now()},
  %{id: Ash.UUID.generate(), resource: Cookbook.Order, resource_id: order.id, action: :notify, observed_at: DateTime.utc_now()}
]

Steward.SagaExecutor.execute(plan)
#=> {:error, %Reactor.Error.Invalid{...}}  — the restock step failed with :out_of_stock

{:ok, order} = Cookbook.get_order(order.id)
order.status
#=> :placed
```

`refund` genuinely succeeded against the payment gateway, `restock` then failed against the warehouse — and because `restock` isn't the kind of failure that gets retried (`:stale_resource` is the only one that is), the saga undoes `refund` automatically and the order ends up back where it started, not stuck halfway between "refunded" and "not refunded." Check `Steward.Sagas.SagaStep` for that saga's ID and you'll see the audit trail: `refund` marked `:succeeded` then `:undone`, `restock` marked `:failed` with disposition `:dropped`.

## Recipe 3: Paying an invoice through a real HTTP call to a Stripe-shaped API

Recipe 1's payment gateway is an in-memory table pretending to be a backend. This one makes an actual HTTP request — to [`stripe-mock`](https://github.com/stripe/stripe-mock), Stripe's own open-source server that validates request/response shape against Stripe's real API schema. No Stripe account or credentials needed.

**Before running this one**, start it in a separate terminal:

```bash
brew install stripe-mock
stripe-mock   # listens on :12111 (http) and :12112 (https) by default
```

```elixir
alias Steward.Cookbook
alias Steward.MCP.Facade
alias Hermes.Server.Frame

{:ok, frame} = Facade.init(%{}, Frame.new())

invoice =
  Steward.borrow({Cookbook.StripeInvoice, :new}, :exclusive, fn token ->
    Cookbook.create_stripe_invoice!("acme-stripe-1001", Ecto.UUID.generate(), Decimal.new(500),
      context: Steward.witness(token)
    )
  end)

{:reply, _approved, frame} =
  Facade.handle_tool_call("approve_stripe_invoice", %{"resource_id" => invoice.id}, frame)

{:reply, paid, _frame} =
  Facade.handle_tool_call(
    "pay_stripe_invoice",
    %{"resource_id" => invoice.id, "amount_paid" => "500"},
    frame
  )

paid.structured_content["status"]
#=> "paid"

Steward.Cookbook.StripeGateway.fetch(invoice.external_id)
#=> {:ok, %{version: 1, state: %{status: :paid, amount_paid: Decimal.new("500"), stripe_payment_intent_id: "pi_..."}}}
```

That `stripe_payment_intent_id` is a real object id, handed back by a real HTTP response from `stripe-mock` — `pay_stripe_invoice` genuinely posted to `/v1/payment_intents` with a real `Idempotency-Key` header (the plan step's fencing token) and parsed a real Stripe-shaped JSON body back.

### The honest limit of this recipe

`stripe-mock` validates shape, not state — verified by hand while building this: POST a value in `metadata` on create, immediately re-fetch the same object by id, and it comes back empty. Nothing round-trips. So the one thing `write/5` exists to prove — "does the backend reject a write whose expected version already drifted" — can't be demonstrated by `stripe-mock`'s own responses here, the way Recipe 1's "two concurrent payments" race genuinely can. `Steward.Cookbook.StripeGateway` keeps that check exactly where Recipe 1's gateway keeps it: a small local table standing in for "what we last knew the backend to hold." What this recipe actually proves is narrower and still real: the adapter's HTTP-facing shape — the request, the idempotency header, the response parsing — holds up against something that looks like Stripe's real API, not just a friendly fake.

The `Idempotency-Key` header carries the saga step's own key (`Steward.Idempotency.step_key/2`), derived once from `{saga_id, step_id}` and therefore identical on every retry of that step — including a retry that arrives minutes later via `Steward.SagaExecutor.resume/1`, in a different process, after the original attempt's process died. It is emphatically *not* the fencing token, which changes with every new lease by design: sending that as the idempotency key would mean the retry after an ambiguous timeout presented Stripe with a key it had never seen, and the customer paid twice.

## Connecting a real MCP client

Everything above calls `Steward.MCP.Facade` directly — the same code path a real client hits, minus the actual wire protocol. To see it end to end with a real client (Claude Code, Claude Desktop, or anything else that speaks MCP), point it at `http://localhost:4000/mcp` (StreamableHTTP transport) while `mix phx.server` is running, and ask it to call `approve_invoice` / `pay_invoice` with a `resource_id` you created via `Steward.Cookbook.create_invoice!/4` in an `iex` session first — the client only ever sees the tool call and its structured result, never the payment gateway itself.
