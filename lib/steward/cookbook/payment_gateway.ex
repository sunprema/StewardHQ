defmodule Steward.Cookbook.PaymentGateway do
  @moduledoc """
  A dummy `Steward.Backend` standing in for a real payment processor
  (Stripe, etc.) — dev-only, in-memory, existing purely so
  `docs/cookbook.md`'s recipes have a real (if simulated) external system
  for `Steward.Changes.EnforceFencing` to fence writes against.

  Structured exactly like `Steward.Test.FakeBackend` (the one mock
  boundary CLAUDE.md's testing convention allows), but living under
  `lib/` — not `test/support/` — since it needs to be compiled and
  reachable in `:dev`, not just `:test`. Only ever *wired up* in
  `config/dev.exs`, though: registering `Steward.Cookbook`'s domain and
  exposing its resources through `Steward.MCP.Facade` — never in
  `test.exs` or `prod.exs`, and never part of the application's
  supervision tree — is what actually confines this to dev. This module
  lazily creates its own backing ETS table on first use for exactly that
  reason: nothing needs to be started for it.

  `simulate_external_write/2` exists so a cookbook recipe can
  *deterministically* trigger `{:error, :stale_resource, remote_state}`
  on the next fenced write — a real conflict, on demand, rather than
  hoping for a race.

  ## Idempotent replay

  `write/5` records the snapshot it produced against the call's
  `opts[:idempotency_key]`, and a later call with the same key replays
  that snapshot instead of writing again — the in-memory stand-in for
  what a real gateway does with `Idempotency-Key`, so the cookbook's
  retry paths behave the way a real one would (spec §4.2). A rejected
  (stale) write is deliberately *not* recorded: it never happened, and
  the retry after a resync has to get through.
  """

  @behaviour Steward.Backend

  @table :steward_cookbook_payment_gateway

  @doc """
  Simulates a write from outside StewardHQ (another writer the gateway
  doesn't control, per docs/tech_spec.md §4.2): bumps the stored version
  without going through `write/4`, so the next fenced write using an
  older expected version observes real drift.
  """
  @spec simulate_external_write(term(), map()) :: :ok
  def simulate_external_write(resource_id, changes \\ %{}) do
    ensure_table()
    {version, state} = fetch_raw(resource_id)
    :ets.insert(@table, {resource_id, version + 1, Map.merge(state, changes)})
    :ok
  end

  @impl true
  def fetch(resource_id) do
    ensure_table()
    {version, state} = fetch_raw(resource_id)
    {:ok, %{version: version, state: state}}
  end

  @impl true
  def write(resource_id, changes, fencing_token, expected_version, opts) do
    ensure_table()

    case replayed(opts[:idempotency_key]) do
      {:ok, snapshot} -> {:ok, snapshot}
      :none -> do_write(resource_id, changes, fencing_token, expected_version, opts)
    end
  end

  defp do_write(resource_id, changes, _fencing_token, expected_version, opts) do
    {current_version, current_state} = fetch_raw(resource_id)

    if current_version == expected_version do
      new_state = Map.merge(current_state, changes)
      new_version = current_version + 1
      :ets.insert(@table, {resource_id, new_version, new_state})
      snapshot = %{version: new_version, state: new_state}
      record_key(opts[:idempotency_key], snapshot)
      {:ok, snapshot}
    else
      {:error, :stale_resource, current_state}
    end
  end

  defp replayed(nil), do: :none

  defp replayed(key) do
    case :ets.lookup(@table, {:idempotency, key}) do
      [{_key, snapshot}] -> {:ok, snapshot}
      [] -> :none
    end
  end

  defp record_key(nil, _snapshot), do: :ok

  defp record_key(key, snapshot) do
    :ets.insert(@table, {{:idempotency, key}, snapshot})
    :ok
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
    # Lost a race with another process also lazily creating this table —
    # it exists now either way, which is all this guards for.
    ArgumentError -> :ok
  end
end
