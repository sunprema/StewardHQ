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
  against the *child's own pid* — if the child dies for any reason, its
  capabilities are auto-expired regardless of cooperative cleanup. That
  monitor is the authoritative backstop.

  For that backstop to mean "no capability outlives its plan", the child
  itself has to die when the plan does. It holds a `Process.monitor` on
  its spawning process for its **whole** lifetime, not just before the
  task arrives, and it runs the caller's `:task` function in a separate
  monitored worker process rather than inline. That indirection is the
  point: a process blocked inside `task.(capabilities)` cannot observe
  anything, so a child that ran the task inline would notice its parent's
  death only once the task finished — which for an agent task is
  unbounded, and can be never. With the worker split out, the child sits
  in a `receive` watching both, and whichever dies first decides:

    * parent dies first — the worker is killed and the child exits,
      expiring every capability it holds. This is the invariant.
    * worker finishes or crashes first — the child exits with the
      worker's reason, so a crashing sub-agent still looks like a
      crashing sub-agent to whoever is monitoring it.

  `Task.Supervisor.start_child/2` deliberately does not link the child to
  its spawner (a sub-agent crash must not take the plan down with it), so
  this monitor is what supplies the other half of that relationship.

  One bounded gap remains, unchanged: while the child is blocked in
  `Steward.ChannelServer.receive_message/4` waiting for its task, it
  cannot act on the parent's death until that call returns. That wait
  carries a 5s timeout, so the window is bounded by construction, and the
  capability monitor still expires everything once the child exits.

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
  spec §4.4), the child is killed before `opts[:task]` ever runs and
  that error is returned. A partial move needs no unwinding of its own:
  the capabilities that *did* move are held by the child, so killing it
  expires them through `Steward.CapabilityRegistry`'s monitor. The
  sender's originals stay `:moved` either way — a move is not undone by
  the delivery failing, which is what keeps linearity total.
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

    with {:ok, moved} <- move_all(moves, task_pid),
         :ok <- send_task(instance_id, task, moved) do
      {:ok, task_pid}
    else
      {:error, reason} ->
        teardown(task_pid, instance_id)
        {:error, reason}
    end
  end

  defp send_task(instance_id, task, capabilities) do
    ChannelServer.send_message(__MODULE__, :spawn, instance_id, :task, %{
      task: task,
      capabilities: capabilities
    })
  end

  # Killing the child is what releases capabilities already moved into it
  # on a partial failure — `Steward.CapabilityRegistry`'s monitor does the
  # work, so there is nothing to unwind by hand.
  defp teardown(task_pid, instance_id) do
    Process.exit(task_pid, :kill)
    ChannelServerSupervisor.stop(__MODULE__, :spawn, instance_id)
  end

  defp run_child(instance_id, parent) do
    parent_ref = Process.monitor(parent)

    receive do
      {:DOWN, ^parent_ref, :process, ^parent, _reason} -> :ok
    after
      0 -> await_task(instance_id, parent_ref, parent)
    end
  end

  defp await_task(instance_id, parent_ref, parent) do
    result = ChannelServer.receive_message(__MODULE__, :spawn, instance_id, timeout: 5_000)
    ChannelServerSupervisor.stop(__MODULE__, :spawn, instance_id)

    case result do
      {:ok, %{payload: %{task: task, capabilities: capabilities}}} ->
        run_task(fn -> task.(capabilities) end, parent_ref, parent)

      {:error, _reason} ->
        Process.demonitor(parent_ref, [:flush])
        :ok
    end
  end

  # The task runs in its own process so this one keeps a free mailbox to
  # watch the parent with. Running it inline would mean the parent's
  # death goes unnoticed for as long as the task runs — which is
  # unbounded, and is exactly how a capability outlives its plan.
  #
  # `spawn_link` plus `trap_exit`, not `spawn_monitor`: the link is what
  # makes the relationship symmetric. A monitor alone would let the
  # worker keep running if *this* process were killed, orphaning it; the
  # link kills it instead. Trapping is what stops the same link from
  # turning an ordinary sub-agent crash into a crash here before the
  # `exit(reason)` below can attribute it.
  defp run_task(work, parent_ref, parent) do
    Process.flag(:trap_exit, true)
    worker = spawn_link(work)

    receive do
      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        # The plan is gone: the task has no standing to continue, and
        # exiting here expires every capability held by this process.
        stop(worker)

      {:EXIT, ^worker, :normal} ->
        Process.demonitor(parent_ref, [:flush])
        :ok

      {:EXIT, ^worker, reason} ->
        # Surface the sub-agent's failure as this process's failure, so a
        # crashing task still reads as a crashing child to anything
        # monitoring or supervising it.
        Process.demonitor(parent_ref, [:flush])
        exit(reason)

      # Anything else linked to us shutting down — the task supervisor on
      # application stop, say. Trapping exits means it arrives as a
      # message rather than killing us, so take the worker down and go.
      {:EXIT, _other, _reason} ->
        stop(worker)
    end
  end

  defp stop(worker) do
    Process.exit(worker, :kill)
    :ok
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
