defmodule Steward.ResourceServer do
  @moduledoc """
  One GenServer per resource id: local borrow arbitration and queueing
  (spec §4.1 Isolation, §8 Phase 1).

  This is the OTP-side half of the borrow checker described in the spec's
  "Witness Pattern": it grants `:shared` (read) or `:exclusive` (write)
  borrows, queues conflicting requests in FIFO order, and guarantees
  release when a holder process dies via `Process.monitor` — per
  CLAUDE.md's invariant "capabilities never outlive their holder" and the
  convention "never trust cooperative cleanup". This module does not (and
  must not) contain business logic: arbitration only.

  Two-tier arbitration (spec §3.2): this is the *local*, cheap first-line
  tier that stops StewardHQ's own agents from requesting conflicting
  leases against each other. Backend lease acquisition (the authoritative
  tier) is Phase 2.
  """

  use GenServer

  @default_timeout 5_000

  defstruct resource_id: nil,
            shared: %{},
            exclusive: nil,
            monitors: %{},
            queue: :queue.new()

  ## Public API

  def start_link(resource_id) do
    GenServer.start_link(__MODULE__, resource_id, name: Steward.Registry.via_tuple(resource_id))
  end

  def child_spec(resource_id) do
    %{
      id: {__MODULE__, resource_id},
      start: {__MODULE__, :start_link, [resource_id]},
      restart: :transient
    }
  end

  @doc """
  Requests a `:shared` or `:exclusive` borrow of `resource_id`.

  If the borrow cannot be granted immediately, the request queues in FIFO
  order. Every call is bounded: if the request is still queued after
  `:timeout` (default #{@default_timeout}ms), it is dropped from the queue
  and `{:error, :timeout}` is returned — this process never waits
  indefinitely (CLAUDE.md: "no infinite receive").
  """
  @spec acquire(term(), :shared | :exclusive, keyword()) ::
          {:ok, reference()} | {:error, :timeout}
  def acquire(resource_id, mode, opts \\ []) when mode in [:shared, :exclusive] do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    {:ok, pid} = Steward.ResourceServerSupervisor.ensure_started(resource_id)
    GenServer.call(pid, {:acquire, mode, self(), timeout}, timeout + 1_000)
  end

  @doc """
  Releases a borrow previously granted by `acquire/3`. Safe to call more
  than once for the same `borrow_ref` — the second call is a no-op that
  returns `{:error, :not_borrowed}` rather than raising.
  """
  @spec release(term(), reference()) :: :ok | {:error, :not_borrowed}
  def release(resource_id, borrow_ref) do
    case Steward.Registry.whereis(resource_id) do
      {:ok, pid} -> GenServer.call(pid, {:release, borrow_ref})
      :error -> {:error, :not_borrowed}
    end
  end

  @doc """
  Function-scoped borrow (spec §4.1 / §8 Phase 1): acquires `mode` on
  `resource_id`, runs `fun`, and guarantees release on any exit from
  `fun` — normal return, raised exception, or thrown value. If the
  calling process itself is killed outright, `fun`'s `after` clause never
  runs, but this resource server's `Process.monitor` on the caller
  releases the borrow independently, so release is guaranteed either way.
  """
  @spec borrow(term(), :shared | :exclusive, (-> result)) :: result | {:error, :timeout}
        when result: var
  def borrow(resource_id, mode, fun) when is_function(fun, 0) do
    case acquire(resource_id, mode) do
      {:ok, borrow_ref} ->
        try do
          fun.()
        after
          release(resource_id, borrow_ref)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Introspection helper for tests/tooling: current holders and queue depth."
  @spec borrows(term()) :: %{
          shared: [reference()],
          exclusive: reference() | nil,
          queue_length: non_neg_integer()
        }
  def borrows(resource_id) do
    case Steward.Registry.whereis(resource_id) do
      {:ok, pid} -> GenServer.call(pid, :borrows)
      :error -> %{shared: [], exclusive: nil, queue_length: 0}
    end
  end

  ## GenServer callbacks

  @impl true
  def init(resource_id) do
    {:ok, %__MODULE__{resource_id: resource_id}}
  end

  @impl true
  def handle_call({:acquire, mode, holder_pid, wait_timeout}, from, state) do
    if grantable?(state, mode) do
      {borrow_ref, state} = do_grant(state, mode, holder_pid)
      {:reply, {:ok, borrow_ref}, state}
    else
      timer_ref = Process.send_after(self(), {:acquire_timeout, from}, wait_timeout)
      waiter = %{from: from, mode: mode, holder_pid: holder_pid, timer_ref: timer_ref}
      {:noreply, %{state | queue: :queue.in(waiter, state.queue)}}
    end
  end

  def handle_call({:release, borrow_ref}, _from, state) do
    case take_holder(state, borrow_ref) do
      {:ok, monitor_ref, state} ->
        Process.demonitor(monitor_ref, [:flush])
        state = %{state | monitors: Map.delete(state.monitors, monitor_ref)}
        {:reply, :ok, grant_from_queue(state)}

      :error ->
        {:reply, {:error, :not_borrowed}, state}
    end
  end

  def handle_call(:borrows, _from, state) do
    reply = %{
      shared: Map.keys(state.shared),
      exclusive: elem(state.exclusive || {nil, nil}, 0),
      queue_length: :queue.len(state.queue)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{borrow_ref, mode}, monitors} ->
        state = %{state | monitors: monitors}

        state =
          case mode do
            :shared -> %{state | shared: Map.delete(state.shared, borrow_ref)}
            :exclusive -> %{state | exclusive: nil}
          end

        {:noreply, grant_from_queue(state)}
    end
  end

  def handle_info({:acquire_timeout, from}, state) do
    case pop_waiter(state.queue, from) do
      {:ok, queue} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | queue: queue}}

      # Already granted (or already removed) before the timer fired: ignore.
      :error ->
        {:noreply, state}
    end
  end

  ## Internal

  defp grantable?(state, mode) do
    :queue.is_empty(state.queue) and grantable_state?(state, mode)
  end

  defp grantable_state?(state, :shared), do: is_nil(state.exclusive)

  defp grantable_state?(state, :exclusive),
    do: is_nil(state.exclusive) and map_size(state.shared) == 0

  defp do_grant(state, mode, holder_pid) do
    borrow_ref = make_ref()
    monitor_ref = Process.monitor(holder_pid)
    state = %{state | monitors: Map.put(state.monitors, monitor_ref, {borrow_ref, mode})}

    state =
      case mode do
        :shared -> %{state | shared: Map.put(state.shared, borrow_ref, monitor_ref)}
        :exclusive -> %{state | exclusive: {borrow_ref, monitor_ref}}
      end

    {borrow_ref, state}
  end

  defp take_holder(state, borrow_ref) do
    cond do
      Map.has_key?(state.shared, borrow_ref) ->
        {monitor_ref, shared} = Map.pop(state.shared, borrow_ref)
        {:ok, monitor_ref, %{state | shared: shared}}

      match?({^borrow_ref, _monitor_ref}, state.exclusive) ->
        {_borrow_ref, monitor_ref} = state.exclusive
        {:ok, monitor_ref, %{state | exclusive: nil}}

      true ->
        :error
    end
  end

  defp grant_from_queue(state) do
    case :queue.out(state.queue) do
      {{:value, waiter}, rest} ->
        candidate_state = %{state | queue: rest}

        if grantable_state?(candidate_state, waiter.mode) do
          Process.cancel_timer(waiter.timer_ref)
          {borrow_ref, granted_state} = do_grant(candidate_state, waiter.mode, waiter.holder_pid)
          GenServer.reply(waiter.from, {:ok, borrow_ref})
          grant_from_queue(granted_state)
        else
          state
        end

      {:empty, _rest} ->
        state
    end
  end

  defp pop_waiter(queue, from) do
    list = :queue.to_list(queue)

    case Enum.split_with(list, fn waiter -> waiter.from == from end) do
      {[], _rest} -> :error
      {[_waiter], rest} -> {:ok, :queue.from_list(rest)}
    end
  end
end
