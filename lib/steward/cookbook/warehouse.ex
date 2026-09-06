defmodule Steward.Cookbook.Warehouse do
  @moduledoc """
  A dummy `Steward.Backend` standing in for a real inventory/fulfillment
  system — dev-only, in-memory, the second external system
  `docs/cookbook.md`'s "cancel an order" recipe fences writes against
  (see `Steward.Cookbook.PaymentGateway`'s moduledoc for why this lives
  under `lib/` but is only ever wired up in `config/dev.exs`).

  `simulate_failure/2` is this backend's version of a deterministic,
  on-demand conflict: rather than a version mismatch, it makes the
  *next* write to `resource_id` fail outright with the given reason
  (e.g. `:out_of_stock`) — this is what lets the "cancel an order"
  recipe reliably demonstrate a saga rolling back an already-succeeded
  step (the refund) because a *later* step (the restock) failed, on
  demand rather than by chance.

  ## Deliberately `idempotency :none`

  Unlike `Steward.Cookbook.PaymentGateway`, this backend accepts
  `opts[:idempotency_key]` and ignores it. That is not an oversight:
  plenty of legacy systems have no idempotency semantics at all, and
  spec §4.2 has a different answer for them — "the fallback is a
  deep-sync repair step... poll the backend's read endpoint to determine
  what actually happened." Keeping one of the cookbook's two backends
  honest about that gives `Steward.RepairLoop` something real to be the
  answer to.
  """

  @behaviour Steward.Backend

  @table :steward_cookbook_warehouse
  @failures_table :steward_cookbook_warehouse_failures

  @doc """
  Makes the next `write/5` call against `resource_id` fail with
  `{:error, reason}` instead of actually writing — consumed on use, so
  the call after that one succeeds normally.
  """
  @spec simulate_failure(term(), atom()) :: :ok
  def simulate_failure(resource_id, reason) do
    ensure_tables()
    :ets.insert(@failures_table, {resource_id, reason})
    :ok
  end

  @impl true
  def fetch(resource_id) do
    ensure_tables()
    {version, state} = fetch_raw(resource_id)
    {:ok, %{version: version, state: state}}
  end

  @impl true
  def write(resource_id, changes, _fencing_token, expected_version, _opts) do
    ensure_tables()

    case :ets.take(@failures_table, resource_id) do
      [{^resource_id, reason}] ->
        {:error, reason}

      [] ->
        do_write(resource_id, changes, expected_version)
    end
  end

  defp do_write(resource_id, changes, expected_version) do
    {current_version, current_state} = fetch_raw(resource_id)

    if current_version == expected_version do
      new_state = Map.merge(current_state, changes)
      new_version = current_version + 1
      :ets.insert(@table, {resource_id, new_version, new_state})
      {:ok, %{version: new_version, state: new_state}}
    else
      {:error, :stale_resource, current_state}
    end
  end

  defp fetch_raw(resource_id) do
    case :ets.lookup(@table, resource_id) do
      [{^resource_id, version, state}] -> {version, state}
      [] -> {0, %{}}
    end
  end

  defp ensure_tables do
    ensure_table(@table)
    ensure_table(@failures_table)
  end

  defp ensure_table(table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end
end
