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
  def write(resource_id, changes, fencing_token, expected_version) do
    ensure_table()
    {current_version, current_state} = fetch_raw(resource_id)

    if current_version == expected_version do
      do_write(resource_id, changes, fencing_token, current_version, current_state)
    else
      {:error, :stale_resource, current_state}
    end
  end

  defp do_write(resource_id, changes, fencing_token, current_version, current_state) do
    amount_cents =
      current_state |> Map.merge(changes) |> Map.get(:amount_paid) |> to_amount_cents()

    case ensure_payment_intent(current_state, amount_cents, fencing_token) do
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

  defp ensure_payment_intent(%{stripe_payment_intent_id: stripe_id}, _amount_cents, fencing_token)
       when is_binary(stripe_id) do
    case confirm_payment_intent(stripe_id, fencing_token) do
      {:ok, _response} -> {:ok, stripe_id}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_payment_intent(_state, amount_cents, fencing_token) do
    create_payment_intent(amount_cents, fencing_token)
  end

  defp create_payment_intent(amount_cents, fencing_token) do
    request(:post, "/v1/payment_intents", fencing_token,
      amount: amount_cents || 0,
      currency: "usd"
    )
    |> case do
      {:ok, %{"id" => id}} -> {:ok, id}
      error -> error
    end
  end

  defp confirm_payment_intent(stripe_id, fencing_token) do
    request(:post, "/v1/payment_intents/#{stripe_id}/confirm", fencing_token,
      payment_method: "pm_card_visa"
    )
  end

  defp get_payment_intent(stripe_id) do
    request(:get, "/v1/payment_intents/#{stripe_id}", nil, [])
  end

  defp request(method, path, fencing_token, form) do
    headers = if fencing_token, do: [{"idempotency-key", to_string(fencing_token)}], else: []

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
