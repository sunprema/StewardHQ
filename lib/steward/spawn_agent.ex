defmodule Steward.SpawnAgent do
  @moduledoc """
  `spawn_agent/2` (docs/tech_spec.md §3.4, §8 Phase 5): "spawn_agent is a
  channel with one message... the degenerate case: capacity 1, one
  `:task` message, no reply expected." Sub-agent spawning is reimplemented
  on top of `Steward.Channel` (deliverable unchanged from spec v2.3, now
  channel-backed) instead of a bespoke path, so it gets the same
  bounded/typed/expiry machinery as any other channel for free.

  ## Plan-scoping (CLAUDE.md invariant 4: "no capability outlives its plan")

  The spawned task runs under `Steward.SpawnAgent.TaskSupervisor` (a
  plain `Task.Supervisor`, started in `Steward.Application`). Each moved
  capability is independently monitored by `Steward.CapabilityRegistry`
  against the *child's own pid* — if the child dies (crash, or its
  spawning process died first and it self-terminates, see below), the
  capability is auto-expired regardless of cooperative cleanup. That
  monitor is the authoritative backstop.

  The child also monitors its spawning process directly and exits
  without ever touching its capabilities if the parent is already dead
  by the time it looks — a fast-fail optimization, not the safety
  mechanism itself (the `Process.monitor`-based auto-release above holds
  regardless, per CLAUDE.md: "never trust cooperative cleanup"). This
  check happens once, before blocking on the channel; a parent dying
  *while* the child is blocked in `Steward.ChannelServer.receive_message/4`
  is not caught until that call returns — a known, bounded race (bounded
  by the receive timeout), not a correctness gap, since the capability
  monitor still catches it once the child eventually dies.

  ## Deviation from the spec's illustrative syntax

  The spec's shorthand is `spawn_agent(name, moves: [caps])` — it never
  shows where the child's actual work comes from. This implementation
  requires it explicitly as the `:task` option:

      Steward.SpawnAgent.spawn_agent(:process_payment,
        task: fn capabilities -> ... end,
        moves: [capability]
      )

  `task` is called with the list of capabilities *as moved* (fresh refs,
  held by the child) once they arrive over the channel.
  """

  use Steward.Channel

  alias Steward.{CapabilityRegistry, ChannelServer, ChannelServerSupervisor}

  channels do
    channel :spawn do
      capacity(1)
      overflow(:reject)
      message :task
    end
  end

  @doc """
  Spawns a supervised, plan-scoped sub-agent task named `name`, moving
  `opts[:moves]` (a list of `Steward.Capability.t()`) into it before it
  runs `opts[:task]`.

  Returns `{:ok, pid}` once the task has been started and the
  capabilities handed off. If any capability can't be moved
  (`{:error, :capability_moved}` or `{:error, :capability_expired}` —
  spec §4.4), the task is torn down before `opts[:task]` ever runs, and
  that error is returned. A partial move (some capabilities already
  moved before a later one fails) is a known v1 limitation — see
  `Steward.ChannelServer`'s moduledoc for the parallel caveat on
  multi-hop delegation.
  """
  @spec spawn_agent(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn_agent(name, opts) when is_atom(name) and is_list(opts) do
    task = Keyword.fetch!(opts, :task)
    moves = Keyword.get(opts, :moves, [])
    parent = self()
    instance_id = {name, make_ref()}

    {:ok, task_pid} =
      Task.Supervisor.start_child(__MODULE__.TaskSupervisor, fn ->
        run_child(instance_id, parent)
      end)

    case move_all(moves, task_pid) do
      {:ok, moved} ->
        :ok =
          ChannelServer.send_message(__MODULE__, :spawn, instance_id, :task, %{
            task: task,
            capabilities: moved
          })

        {:ok, task_pid}

      {:error, reason} ->
        Process.exit(task_pid, :kill)
        ChannelServerSupervisor.stop(__MODULE__, :spawn, instance_id)
        {:error, reason}
    end
  end

  defp run_child(instance_id, parent) do
    monitor_ref = Process.monitor(parent)

    receive do
      {:DOWN, ^monitor_ref, :process, ^parent, _reason} -> :ok
    after
      0 -> await_task(instance_id, monitor_ref)
    end
  end

  defp await_task(instance_id, monitor_ref) do
    result = ChannelServer.receive_message(__MODULE__, :spawn, instance_id, timeout: 5_000)
    ChannelServerSupervisor.stop(__MODULE__, :spawn, instance_id)
    Process.demonitor(monitor_ref, [:flush])

    case result do
      {:ok, %{payload: %{task: task, capabilities: capabilities}}} -> task.(capabilities)
      {:error, _reason} -> :ok
    end
  end

  defp move_all(moves, task_pid) do
    moves
    |> Enum.reduce_while({:ok, []}, fn capability, {:ok, acc} ->
      case CapabilityRegistry.move(capability, task_pid) do
        {:ok, moved} -> {:cont, {:ok, [moved | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, moved} -> {:ok, Enum.reverse(moved)}
      {:error, _reason} = error -> error
    end
  end
end
