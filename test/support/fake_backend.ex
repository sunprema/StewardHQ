defmodule Steward.Test.FakeBackend do
  @moduledoc """
  In-memory `Steward.Backend` implementation for tests — the one mock
  boundary CLAUDE.md's testing convention allows ("mock only the
  legacy-API boundary... this is the one seam v1 does abstract").

  Backed by a single named public ETS table created once in
  `test/test_helper.exs`, keyed by `resource_id`. Tests stay isolated the
  same way `Steward.ResourceServerTest` already isolates: by using a
  unique `resource_id` per test, not by process ownership.

  ## Idempotent replay

  `write/5` records the snapshot it produced against the call's
  `opts[:idempotency_key]`. A second call carrying the same key returns
  that stored snapshot verbatim without touching state — the in-memory
  equivalent of what a real gateway does with `Idempotency-Key`, and
  what makes retrying an ambiguous write safe (spec §4.2's phantom
  payment). A `nil` key opts out, which is the `idempotency :none` case.
  """

  @behaviour Steward.Backend

  @table :steward_fake_backend

  @doc "Creates the backing ETS table. Call once, e.g. from test_helper.exs."
  def init_table do
    :ets.new(@table, [:named_table, :public, :set])
  end

  @doc "Seeds `resource_id` with an initial version and state, as if written by the legacy system directly."
  @spec seed(term(), term(), map()) :: :ok
  def seed(resource_id, version, state) do
    :ets.insert(@table, {resource_id, version, state})
    :ok
  end

  @doc """
  Simulates a write from outside StewardHQ (another writer the gateway
  doesn't control, per spec §4.2): bumps the stored version without
  going through `write/4`, so a subsequent fenced write using the old
  expected version observes drift.
  """
  @spec simulate_external_write(term(), map()) :: :ok
  def simulate_external_write(resource_id, changes \\ %{}) do
    {version, state} = fetch_raw(resource_id)
    :ets.insert(@table, {resource_id, version + 1, Map.merge(state, changes)})
    :ok
  end

  @impl true
  def fetch(resource_id) do
    {version, state} = fetch_raw(resource_id)
    {:ok, %{version: version, state: state}}
  end

  @doc "How many times `write/5` actually reached state, as opposed to replaying a stored result."
  @spec write_count(term()) :: non_neg_integer()
  def write_count(resource_id) do
    case :ets.lookup(@table, {:writes, resource_id}) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  @impl true
  def write(resource_id, changes, fencing_token, expected_version, opts) do
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
      :ets.update_counter(@table, {:writes, resource_id}, 1, {{:writes, resource_id}, 0})
      snapshot = %{version: new_version, state: new_state}
      record_key(opts[:idempotency_key], snapshot)
      {:ok, snapshot}
    else
      # A rejected write never happened, so it must not be recorded
      # against the key: the retry that follows a resync has to be
      # allowed through.
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
end
