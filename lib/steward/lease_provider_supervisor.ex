defmodule Steward.LeaseProviderSupervisor do
  @moduledoc """
  DynamicSupervisor that starts one `Steward.LeaseProvider` per
  `resource_id`, on demand (docs/tech_spec.md §8 Phase 2).
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Returns the pid of the `Steward.LeaseProvider` for `resource_id`,
  starting it first if it isn't already running.
  """
  @spec ensure_started(term()) :: {:ok, pid()}
  def ensure_started(resource_id) do
    case DynamicSupervisor.start_child(__MODULE__, {Steward.LeaseProvider, resource_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end
