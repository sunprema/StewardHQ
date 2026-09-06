defmodule Steward.Cookbook.StripeGateway do
  @moduledoc """
  A dummy `Steward.Backend`, but unlike `Steward.Cookbook.PaymentGateway`,
  this one makes real HTTP calls — against
  [`stripe-mock`](https://github.com/stripe/stripe-mock) (Stripe's own
  open-source schema-conformance server), not the real Stripe API, so
  no Stripe account or credentials are needed. It exists to answer a
  narrower, more honest question than "does the fencing model work
  end to end against a real payment processor": does
  `Steward.Backend`'s HTTP-facing shape — a real request, a real
  `Idempotency-Key` header, real JSON parsing of a real Stripe-shaped
  response — hold up against something that actually looks like
  Stripe's API, not just an in-memory table pretending to?

  ## The honest limitation

  `stripe-mock` validates request/response *shape* against Stripe's
  published API schema — it does not persist state. Verified by hand:
  POSTing `metadata` on create and immediately re-fetching the same
  object by id comes back with empty metadata; nothing round-trips.
  That means the one thing `write/4` exists to prove — "does the
  backend reject a write whose expected version has already drifted" —
  can't be demonstrated by `stripe-mock`'s own responses, since it has
  no real version to drift.

  So version/conflict tracking here lives in exactly the same place it
  does in `Steward.Cookbook.PaymentGateway`: a small local ETS table
  standing in for "what we last knew the backend to hold." The HTTP
  round trip to `stripe-mock` still happens on every `fetch/1`/`write/4`
  — that part is real — its response just isn't what this module trusts
  to decide whether a write is stale.

  ## Idempotency keys are not fencing tokens

  This module declares `idempotency :header` (spec §6) and sends
  `opts[:idempotency_key]` — the caller's stable, per-step key from
  `Steward.Idempotency.step_key/2` — in Stripe's `Idempotency-Key`
  header.

  It previously sent the *fencing token* there instead, which looks
  reasonable and is exactly backwards. A fencing token changes with
  every new lease, by design (spec §3.2, "monotonically increasing"). So
  the retry that follows an ambiguous failure — a timeout on a charge
  that may or may not have gone through — would take a fresh lease, get
  a fresh token, and present Stripe with a key it had never seen. Stripe
  would treat it as a new charge and the customer would pay twice: the
  phantom payment of spec §4.2, caused by the defense against it.

  The fencing token is no longer sent over HTTP at all. Stripe has no
  conditional-write primitive to spend it on (no `If-Match` on
  `/v1/payment_intents`), so fencing is enforced before the call, in the
  version check in `write/5` — the `locking :conditional_write` tier of
  spec §6's fallback ladder, implemented locally because this backend
  sits at the `:serialized` end of it.

  Create and confirm are two different requests with different
  parameters, so they carry two derived keys (`...:create`,
  `...:confirm`). Reusing one key across both would be rejected by real
  Stripe, which treats a repeated key with different parameters as an
  error rather than a replay.

  Requires `stripe-mock` running locally — see `docs/cookbook.md`.
  Dev-only, same as every other `Steward.Cookbook` module (see
  `Steward.Cookbook.PaymentGateway`'s moduledoc for why).
  """

  @behaviour Steward.Backend

  @table :steward_cookbook_stripe_gateway

  @impl true
  def fetch(resource_id) do
    ensure_table()
    {version, state} = fetch_raw(resource_id)

    # A real HTTP round trip, for protocol realism only — per this
    # module's moduledoc, its response isn't consulted for version or
    # state, since stripe-mock has nothing real to tell us.
    case Map.get(state, :stripe_payment_intent_id) do
      nil -> :ok
      stripe_id -> get_payment_intent(stripe_id)
    end

    {:ok, %{version: version, state: state}}
  end

  @impl true
  def write(resource_id, changes, _fencing_token, expected_version, opts) do
    ensure_table()
    {current_version, current_state} = fetch_raw(resource_id)

    # The fencing check, spent here rather than in a header: Stripe has no
    # conditional write to attach it to, so a stale writer is stopped
    # before it can reach the API at all.
    if current_version == expected_version do
      do_write(resource_id, changes, opts[:idempotency_key], current_version, current_state)
    else
      {:error, :stale_resource, current_state}
    end
  end

  defp do_write(resource_id, changes, idempotency_key, current_version, current_state) do
    amount_cents =
      current_state |> Map.merge(changes) |> Map.get(:amount_paid) |> to_amount_cents()

    case ensure_payment_intent(current_state, amount_cents, idempotency_key) do
      {:ok, stripe_id} ->
        new_state =
          current_state |> Map.merge(changes) |> Map.put(:stripe_payment_intent_id, stripe_id)

        new_version = current_version + 1
        :ets.insert(@table, {resource_id, new_version, new_state})
        {:ok, %{version: new_version, state: new_state}}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_payment_intent(%{stripe_payment_intent_id: stripe_id}, _amount_cents, key)
       when is_binary(stripe_id) do
    case confirm_payment_intent(stripe_id, key) do
      {:ok, _response} -> {:ok, stripe_id}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_payment_intent(_state, amount_cents, key) do
    create_payment_intent(amount_cents, key)
  end

  defp create_payment_intent(amount_cents, key) do
    request(:post, "/v1/payment_intents", derive(key, "create"),
      amount: amount_cents || 0,
      currency: "usd"
    )
    |> case do
      {:ok, %{"id" => id}} -> {:ok, id}
      error -> error
    end
  end

  defp confirm_payment_intent(stripe_id, key) do
    request(:post, "/v1/payment_intents/#{stripe_id}/confirm", derive(key, "confirm"),
      payment_method: "pm_card_visa"
    )
  end

  # A read is naturally idempotent and carries no key.
  defp get_payment_intent(stripe_id) do
    request(:get, "/v1/payment_intents/#{stripe_id}", nil, [])
  end

  # One key per distinct request. Stripe rejects a repeated key whose
  # parameters differ, so create and confirm cannot share the caller's.
  defp derive(nil, _suffix), do: nil
  defp derive(key, suffix), do: "#{key}:#{suffix}"

  defp request(method, path, idempotency_key, form) do
    # Injected through Steward.Idempotency rather than hand-set, so this
    # backend applies the `idempotency :header` mode spec §6 declares in
    # exactly one place. A nil key degrades to `:none` — no header.
    headers =
      %{}
      |> Steward.Idempotency.inject(idempotency_key, idempotency_mode(idempotency_key))
      |> Map.get(:headers, %{})
      |> Map.to_list()

    result =
      Req.request(
        method: method,
        url: base_url() <> path,
        auth: {:basic, "#{api_key()}:"},
        headers: headers,
        form: form
      )

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:stripe_error, status, body}}
      {:error, reason} -> {:error, {:stripe_unreachable, reason}}
    end
  end

  defp idempotency_mode(nil), do: :none
  defp idempotency_mode(_key), do: :header

  defp to_amount_cents(nil), do: nil

  defp to_amount_cents(%Decimal{} = decimal) do
    decimal |> Decimal.mult(100) |> Decimal.round() |> Decimal.to_integer()
  end

  defp base_url, do: config(:base_url, "http://localhost:12111")
  defp api_key, do: config(:api_key, "sk_test_cookbook")

  defp config(key, default) do
    :steward |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  defp fetch_raw(resource_id) do
    case :ets.lookup(@table, resource_id) do
      [{^resource_id, version, state}] -> {version, state}
      [] -> {0, %{}}
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end
end
