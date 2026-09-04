defmodule Steward.Test.FakeBackend do
  @moduledoc """
  In-memory `Steward.Backend` implementation for tests — the one mock
  boundary CLAUDE.md's testing convention allows ("mock only the
  legacy-API boundary... this is the one seam v1 does abstract").

  Backed by a single named public ETS table created once in
  `test/test_helper.exs`, keyed by `resource_id`. Tests stay isolated the
  same way `Steward.ResourceServerTest` already isolates: by using a
  unique `resource_id` per test, not by process ownership.
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

  @impl true
  def write(resource_id, changes, _fencing_token, expected_version) do
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
end
