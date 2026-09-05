defmodule Steward.ChannelServer do
  @moduledoc """
  One GenServer per running channel *instance*: the bounded,
  GenServer-backed mailbox `Steward.Channel` compiles a declaration for
  (docs/tech_spec.md §3.4, §8 Phase 5).

  A `channel :payment_processing do ... end` block is a declaration, not
  a process — many independent conversations can use the same declared
  channel concurrently (analogous to how one `Steward.Resource` module
  describes many resource ids, each with its own `Steward.ResourceServer`).
  `instance_id` distinguishes them, registered via
  `Steward.Registry.via_tuple({:channel, protocol, channel_name, instance_id})`.

  ## What's enforced here vs. left to the caller

    * **Capacity + overflow** (spec: "Overflow is bounded... `overflow
      :block` always carries a timeout... exceeding it, or `overflow
      :reject`, surfaces `{:error, :channel_full}`") — enforced here,
      exactly as declared. `:reject` fails immediately; `:block` queues
      the sender as a FIFO waiter, bounded by the channel's
      `overflow_timeout`, mirroring `Steward.ResourceServer.acquire/3`'s
      own timer-based waiter queue.
    * **`require_intent`** — enforced here: a send with no `:intent` in
      `opts` fails `{:error, :intent_required}`.
    * **`allow_delegation`** — enforced here for the one thing a channel
      instance can actually check at runtime: that an attached
      capability's `:name` is in the declared list (`{:error,
      :capability_not_delegable}` — a channel-specific, non-taxonomy
      reason since spec §4.4 doesn't cover a channel rejecting a
      capability it never agreed to carry; genuine authority-granting
      still only happens once via `Steward.CapabilityRegistry.issue/4`,
      per the spec: "a channel can't manufacture a right"). The actual
      *move* — consuming the sender's capability and minting the
      receiver's — is `Steward.CapabilityRegistry.move/2`, called once
      when the message is delivered by `send_message/5` (sender → channel)
      and again by `receive_message/4` (channel → receiver): two hops,
      two proper linear moves, never a bypass.
    * **`{:error, :channel_closed}`** — a send or receive against a
      channel instance that has been `close/3`'d. Closing also tears
      down outstanding delegations per CLAUDE.md invariant 4 ("no
      capability outlives its plan") extended to channels (spec §8 Phase
      5: "no capability outlives its channel"): every capability still
      sitting in the queue, undelivered, is expired via
      `Steward.CapabilityRegistry` rather than silently dropped.

  A known v1 limitation, named directly in spec §3.4's own framing: full
  "oneshot delegation" (the channel itself watching for a paired reply
  and auto-returning the capability on receipt or on the delegate's
  death) is not implemented — only the two-hop move above. That reply-
  tracking machinery is exactly the kind of DSL-surface completeness the
  roadmap (§8 Phase 5) defers ("full DSL surface... deferred").
  """

  use GenServer

  alias Steward.{CapabilityRegistry, Registry}
  alias Steward.Channel.Info

  defstruct protocol: nil,
            channel_name: nil,
            capacity: 100,
            overflow: :reject,
            overflow_timeout: nil,
            allow_delegation: [],
            require_intent: false,
            queue: :queue.new(),
            queue_length: 0,
            send_waiters: :queue.new(),
            receive_waiters: :queue.new(),
            closed?: false

  ## Public API

  def start_link({protocol, channel_name, instance_id}) do
    GenServer.start_link(__MODULE__, {protocol, channel_name},
      name: Registry.via_tuple({:channel, protocol, channel_name, instance_id})
    )
  end

  def child_spec({protocol, channel_name, instance_id} = arg) do
    %{
      id: {__MODULE__, protocol, channel_name, instance_id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :transient
    }
  end

  @typedoc "A queued or delivered message: the declared message name plus its payload."
  @type envelope :: %{message: atom(), payload: map()}

  @doc """
  Sends `message_name` with `payload` on the given channel instance.
  `opts`:

    * `:intent` — required if the channel declares `require_intent true`.
    * `:capability` — a `Steward.Capability.t()` to move into the
      channel (checked against `allow_delegation`); attached to the
      envelope's payload under `:capability` for the receiver to accept
      via `receive_message/4`.
  """
  @spec send_message(module(), atom(), term(), atom(), map(), keyword()) ::
          :ok
          | {:error, :channel_closed}
          | {:error, :channel_full}
          | {:error, :intent_required}
          | {:error, :capability_not_delegable}
          | {:error, :capability_moved}
          | {:error, :capability_expired}
  def send_message(protocol, channel_name, instance_id, message_name, payload, opts \\ []) do
    {:ok, pid} =
      Steward.ChannelServerSupervisor.ensure_started(protocol, channel_name, instance_id)

    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(pid, {:send, message_name, payload, opts, self()}, call_timeout(timeout))
  end

  @doc """
  Receives the next queued message on the given channel instance,
  waiting up to `opts[:timeout]` (default 5000ms) if empty. Moves any
  attached capability to the calling process.
  """
  @spec receive_message(module(), atom(), term(), keyword()) ::
          {:ok, envelope()} | {:error, :channel_closed} | {:error, :timeout}
  def receive_message(protocol, channel_name, instance_id, opts \\ []) do
    {:ok, pid} =
      Steward.ChannelServerSupervisor.ensure_started(protocol, channel_name, instance_id)

    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(pid, {:receive, timeout, self()}, call_timeout(timeout))
  end

  @doc """
  Closes the channel instance: no further sends/receives succeed, and
  every capability still attached to an undelivered, queued message is
  expired (spec §8 Phase 5: "no capability outlives its channel").
  """
  @spec close(module(), atom(), term()) :: :ok
  def close(protocol, channel_name, instance_id) do
    case Registry.whereis({:channel, protocol, channel_name, instance_id}) do
      {:ok, pid} -> GenServer.call(pid, :close)
      :error -> :ok
    end
  end

  @doc """
  Introspection helper for tests/tooling: current queue depth, closed
  state, and the capabilities still attached to undelivered queued
  messages (e.g. to assert on their disposition after `close/3`).
  """
  @spec inspect_state(module(), atom(), term()) :: %{
          queue_length: non_neg_integer(),
          closed?: boolean(),
          queued_capabilities: [Steward.Capability.t()]
        }
  def inspect_state(protocol, channel_name, instance_id) do
    case Registry.whereis({:channel, protocol, channel_name, instance_id}) do
      {:ok, pid} -> GenServer.call(pid, :inspect_state)
      :error -> %{queue_length: 0, closed?: true, queued_capabilities: []}
    end
  end

  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout), do: timeout + 1_000

  ## GenServer callbacks

  @impl true
  def init({protocol, channel_name}) do
    channel = Info.channel!(protocol, channel_name)

    {:ok,
     %__MODULE__{
       protocol: protocol,
       channel_name: channel_name,
       capacity: channel.capacity,
       overflow: channel.overflow,
       overflow_timeout: channel.overflow_timeout,
       allow_delegation: channel.allow_delegation,
       require_intent: channel.require_intent
     }}
  end

  @impl true
  def handle_call({:send, message_name, payload, opts, sender_pid}, from, state) do
    with :ok <- check_open(state),
         :ok <- check_intent(state, opts),
         {:ok, payload} <- attach_capability(state, payload, opts, sender_pid) do
      enqueue_or_overflow(state, message_name, payload, from)
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:receive, wait_timeout, receiver_pid}, from, state) do
    case check_open(state) do
      {:error, _reason} = error ->
        {:reply, error, state}

      :ok ->
        case :queue.out(state.queue) do
          {{:value, envelope}, rest} ->
            state =
              %{state | queue: rest, queue_length: state.queue_length - 1}
              |> wake_next_sender()

            deliver(envelope, receiver_pid, state)

          {:empty, _rest} ->
            timer_ref = Process.send_after(self(), {:receive_timeout, from}, wait_timeout)
            waiter = %{from: from, receiver_pid: receiver_pid, timer_ref: timer_ref}
            {:noreply, %{state | receive_waiters: :queue.in(waiter, state.receive_waiters)}}
        end
    end
  end

  def handle_call(:close, _from, state) do
    Enum.each(:queue.to_list(state.queue), fn envelope ->
      case Map.get(envelope.payload, :capability) do
        %Steward.Capability{} = capability -> CapabilityRegistry.expire(capability)
        nil -> :ok
      end
    end)

    Enum.each(:queue.to_list(state.receive_waiters), fn waiter ->
      Process.cancel_timer(waiter.timer_ref)
      GenServer.reply(waiter.from, {:error, :channel_closed})
    end)

    Enum.each(:queue.to_list(state.send_waiters), fn waiter ->
      Process.cancel_timer(waiter.timer_ref)
      GenServer.reply(waiter.from, {:error, :channel_closed})
    end)

    {:reply, :ok,
     %{
       state
       | closed?: true,
         queue: :queue.new(),
         queue_length: 0,
         receive_waiters: :queue.new(),
         send_waiters: :queue.new()
     }}
  end

  def handle_call(:inspect_state, _from, state) do
    queued_capabilities =
      state.queue
      |> :queue.to_list()
      |> Enum.map(&Map.get(&1.payload, :capability))
      |> Enum.reject(&is_nil/1)

    {:reply,
     %{
       queue_length: state.queue_length,
       closed?: state.closed?,
       queued_capabilities: queued_capabilities
     }, state}
  end

  @impl true
  def handle_info({:send_timeout, from}, state) do
    case pop_waiter(state.send_waiters, from) do
      {:ok, _waiters} -> GenServer.reply(from, {:error, :channel_full})
      :error -> :ok
    end

    {:noreply, %{state | send_waiters: drop_waiter(state.send_waiters, from)}}
  end

  def handle_info({:receive_timeout, from}, state) do
    case pop_waiter(state.receive_waiters, from) do
      {:ok, _waiters} -> GenServer.reply(from, {:error, :timeout})
      :error -> :ok
    end

    {:noreply, %{state | receive_waiters: drop_waiter(state.receive_waiters, from)}}
  end

  ## Internal

  defp check_open(%{closed?: true}), do: {:error, :channel_closed}
  defp check_open(_state), do: :ok

  defp check_intent(%{require_intent: true}, opts) do
    if Keyword.has_key?(opts, :intent), do: :ok, else: {:error, :intent_required}
  end

  defp check_intent(%{require_intent: false}, _opts), do: :ok

  defp attach_capability(state, payload, opts, _sender_pid)
       when not is_map_key(payload, :capability) do
    case Keyword.fetch(opts, :capability) do
      :error -> {:ok, payload}
      {:ok, capability} -> do_attach_capability(state, payload, capability)
    end
  end

  defp attach_capability(_state, payload, _opts, _sender_pid), do: {:ok, payload}

  defp do_attach_capability(
         %{allow_delegation: allowed},
         payload,
         %Steward.Capability{} = capability
       ) do
    if capability.name in allowed do
      case CapabilityRegistry.move(capability, self()) do
        {:ok, moved} -> {:ok, Map.put(payload, :capability, moved)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :capability_not_delegable}
    end
  end

  defp enqueue_or_overflow(state, message_name, payload, from) do
    if state.queue_length < state.capacity do
      state = %{
        state
        | queue: :queue.in(%{message: message_name, payload: payload}, state.queue),
          queue_length: state.queue_length + 1
      }

      {:reply, :ok, maybe_wake_receiver(state)}
    else
      handle_overflow(state, message_name, payload, from)
    end
  end

  defp maybe_wake_receiver(state) do
    case :queue.out(state.receive_waiters) do
      {{:value, waiter}, rest} ->
        Process.cancel_timer(waiter.timer_ref)
        {{:value, envelope}, remaining_queue} = :queue.out(state.queue)

        state =
          %{
            state
            | queue: remaining_queue,
              queue_length: state.queue_length - 1,
              receive_waiters: rest
          }
          |> wake_next_sender()

        {:reply, reply, state} = deliver(envelope, waiter.receiver_pid, state)
        GenServer.reply(waiter.from, reply)
        state

      {:empty, _rest} ->
        state
    end
  end

  defp handle_overflow(%{overflow: :reject} = state, _message_name, _payload, _from) do
    {:reply, {:error, :channel_full}, state}
  end

  defp handle_overflow(%{overflow: :block} = state, message_name, payload, from) do
    timer_ref = Process.send_after(self(), {:send_timeout, from}, state.overflow_timeout)
    waiter = %{from: from, message: message_name, payload: payload, timer_ref: timer_ref}
    {:noreply, %{state | send_waiters: :queue.in(waiter, state.send_waiters)}}
  end

  # A dequeue (either an immediate receive hit, or maybe_wake_receiver
  # draining for a waiting receiver) just freed one queue slot. If a
  # sender is blocked on `overflow :block` waiting for exactly that, let
  # it in now instead of leaving it to time out even though there was
  # room the whole time.
  defp wake_next_sender(state) do
    case :queue.out(state.send_waiters) do
      {{:value, waiter}, rest} ->
        Process.cancel_timer(waiter.timer_ref)

        %{
          state
          | queue: :queue.in(%{message: waiter.message, payload: waiter.payload}, state.queue),
            queue_length: state.queue_length + 1,
            send_waiters: rest
        }
        |> tap(fn _ -> GenServer.reply(waiter.from, :ok) end)

      {:empty, _rest} ->
        state
    end
  end

  defp deliver(envelope, receiver_pid, state) do
    case Map.get(envelope.payload, :capability) do
      %Steward.Capability{} = capability ->
        case CapabilityRegistry.move(capability, receiver_pid) do
          {:ok, moved} ->
            {:reply, {:ok, %{envelope | payload: Map.put(envelope.payload, :capability, moved)}},
             state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      nil ->
        {:reply, {:ok, envelope}, state}
    end
  end

  defp pop_waiter(queue, from) do
    if Enum.any?(:queue.to_list(queue), &(&1.from == from)), do: {:ok, queue}, else: :error
  end

  defp drop_waiter(queue, from) do
    queue |> :queue.to_list() |> Enum.reject(&(&1.from == from)) |> :queue.from_list()
  end
end
