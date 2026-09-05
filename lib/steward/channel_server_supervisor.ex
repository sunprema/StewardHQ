defmodule Steward.ChannelServerSupervisor do
  @moduledoc """
  DynamicSupervisor that starts one `Steward.ChannelServer` per running
  channel *instance*, on demand (docs/tech_spec.md §3.4, §8 Phase 5) —
  the channel analogue of `Steward.ResourceServerSupervisor`.
  """

  use DynamicSupervisor

  alias Steward.Registry

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Returns the pid of the `Steward.ChannelServer` for `{protocol,
  channel_name, instance_id}`, starting it first if it isn't already
  running.
  """
  @spec ensure_started(module(), atom(), term()) :: {:ok, pid()}
  def ensure_started(protocol, channel_name, instance_id) do
    child_spec = {Steward.ChannelServer, {protocol, channel_name, instance_id}}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Stops the `Steward.ChannelServer` for `{protocol, channel_name,
  instance_id}`, if one is running. Used to release a one-shot channel
  instance (e.g. `Steward.SpawnAgent`'s degenerate channel) once its
  single message has been delivered, instead of leaving it registered
  forever.
  """
  @spec stop(module(), atom(), term()) :: :ok
  def stop(protocol, channel_name, instance_id) do
    case Registry.whereis({:channel, protocol, channel_name, instance_id}) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      :error -> :ok
    end

    :ok
  end
end
