defmodule Steward.CapabilityRegistry do
  @moduledoc """
  The authority behind `Steward.Capability` tokens: linear ownership and
  move semantics (docs/tech_spec.md §3.1 `own`; CLAUDE.md invariant 3
  "Capabilities are linear"; CLAUDE.md architecture map's `Steward.Registry`
  moduledoc, which named this exact gap — "Capability token tracking and
  move semantics... belong to Phase 5").

  A single, always-running GenServer (not one-per-resource like
  `Steward.ResourceServer` — a capability's validity is a global fact,
  not local arbitration) holding one map entry per issued capability
  `:ref`: `%{status, holder, monitor_ref}`. Holding a `%Steward.Capability{}`
  struct proves nothing; every caller must come back through here.

  ## Status transitions

    * `issue/4` creates a capability `:active`, held by the calling
      process (or `opts[:holder]`), monitored so its death auto-expires
      it — CLAUDE.md invariant 4, "process death must release borrows
      automatically... never trust cooperative cleanup."
    * `move/2` is spec §3.1's "capabilities are moved into the child
      task. The parent's copy is consumed": the *old* `:ref` is
      permanently marked `:moved` (any further `use_capability/1` or
      `move/2` against it fails `{:error, :capability_moved}`, even from
      a different process), and a *new* capability — same resource,
      same rights, new `:ref`, new holder — is returned.
    * `use_capability/1` exercises the capability in place, without
      moving it. A `consumption: :linear` capability transitions
      `:active` -> `:consumed` on success; `:reusable` capabilities stay
      `:active` indefinitely. Calling it again after `:consumed`, or
      after the holder died, fails `{:error, :capability_expired}` — the
      taxonomy entry the spec's v2.3 addendum distinguishes from
      `:lease_expired` as "applies to §3.1 capability tokens."

  `:capability_moved` and `:capability_expired` are the only two ways a
  capability stops being usable; which one a stale caller sees tells them
  whether the right went somewhere else (moved) or simply ran out
  (expired) — legible failure per spec §4.4.
  """

  use GenServer

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Issues a new, `:active` capability over `{resource, resource_id}`
  named `name`. `opts`:

    * `:consumption` — `:linear` or `:reusable` (default `:reusable`).
    * `:holder` — the owning pid (default `self()`); monitored, so its
      death expires this capability.
  """
  @spec issue(module(), term(), atom(), keyword()) :: {:ok, Steward.Capability.t()}
  def issue(resource, resource_id, name, opts \\ []) do
    consumption = Keyword.get(opts, :consumption, :reusable)
    holder = Keyword.get(opts, :holder, self())

    capability = %Steward.Capability{
      ref: make_ref(),
      resource: resource,
      resource_id: resource_id,
      name: name,
      consumption: consumption
    }

    GenServer.call(__MODULE__, {:issue, capability, holder})
  end

  @doc """
  Moves `capability` to `new_holder`: consumes the sender's copy
  (`:ref` becomes permanently `:moved`) and returns a new capability
  struct with a fresh `:ref`, held by `new_holder`.
  """
  @spec move(Steward.Capability.t(), pid()) ::
          {:ok, Steward.Capability.t()}
          | {:error, :capability_moved}
          | {:error, :capability_expired}
  def move(%Steward.Capability{} = capability, new_holder) when is_pid(new_holder) do
    GenServer.call(__MODULE__, {:move, capability, new_holder})
  end

  @doc """
  Exercises `capability` in place. A `:linear` capability is consumed on
  success (further calls fail `:capability_expired`); a `:reusable` one
  stays active.
  """
  @spec use_capability(Steward.Capability.t()) ::
          :ok | {:error, :capability_moved} | {:error, :capability_expired}
  def use_capability(%Steward.Capability{} = capability) do
    GenServer.call(__MODULE__, {:use, capability})
  end

  @doc """
  Force-expires `capability` regardless of consumption type or current
  status: unlike `use_capability/1`, this also invalidates a `:reusable`
  capability. For teardown paths that aren't a normal use or holder
  death — e.g. `Steward.ChannelServer` closing with the capability still
  sitting undelivered in its queue (spec §8 Phase 5: "no capability
  outlives its channel"). Idempotent; always returns `:ok`.
  """
  @spec expire(Steward.Capability.t()) :: :ok
  def expire(%Steward.Capability{} = capability) do
    GenServer.call(__MODULE__, {:expire, capability.ref})
  end

  @doc "Introspection helper for tests/tooling: this ref's current status, or `:unknown` if never issued."
  @spec status(Steward.Capability.t()) :: :active | :moved | :consumed | :expired | :unknown
  def status(%Steward.Capability{ref: ref}) do
    GenServer.call(__MODULE__, {:status, ref})
  end

  ## GenServer callbacks

  @impl true
  def init(:ok), do: {:ok, %{entries: %{}, monitors: %{}}}

  @impl true
  def handle_call({:issue, capability, holder}, _from, state) do
    monitor_ref = Process.monitor(holder)
    entry = %{status: :active, holder: holder, monitor_ref: monitor_ref}
    state = put_entry(state, capability.ref, entry)
    {:reply, {:ok, capability}, state}
  end

  def handle_call({:move, capability, new_holder}, _from, state) do
    case fetch_active(state, capability.ref) do
      {:ok, entry} ->
        state = retire_entry(state, capability.ref, entry, :moved)

        moved_capability = %{capability | ref: make_ref()}
        monitor_ref = Process.monitor(new_holder)
        new_entry = %{status: :active, holder: new_holder, monitor_ref: monitor_ref}
        state = put_entry(state, moved_capability.ref, new_entry)

        {:reply, {:ok, moved_capability}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:use, capability}, _from, state) do
    case fetch_active(state, capability.ref) do
      {:ok, entry} ->
        state =
          if capability.consumption == :linear do
            retire_entry(state, capability.ref, entry, :consumed)
          else
            state
          end

        {:reply, :ok, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:expire, ref}, _from, state) do
    state =
      case Map.get(state.entries, ref) do
        %{status: status} = entry when status in [:active, :moved] ->
          retire_entry(state, ref, entry, :expired)

        _already_terminal_or_unknown ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:status, ref}, _from, state) do
    status = state.entries |> Map.get(ref, %{status: :unknown}) |> Map.fetch!(:status)
    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {ref, monitors} ->
        entry = Map.fetch!(state.entries, ref)
        entries = Map.put(state.entries, ref, %{entry | status: :expired})
        {:noreply, %{state | entries: entries, monitors: monitors}}
    end
  end

  ## Internal

  defp put_entry(state, ref, entry) do
    %{
      state
      | entries: Map.put(state.entries, ref, entry),
        monitors: Map.put(state.monitors, entry.monitor_ref, ref)
    }
  end

  defp retire_entry(state, ref, entry, new_status) do
    Process.demonitor(entry.monitor_ref, [:flush])

    %{
      state
      | entries: Map.put(state.entries, ref, %{entry | status: new_status}),
        monitors: Map.delete(state.monitors, entry.monitor_ref)
    }
  end

  defp fetch_active(state, ref) do
    case Map.get(state.entries, ref) do
      %{status: :active} = entry -> {:ok, entry}
      %{status: :moved} -> {:error, :capability_moved}
      %{status: status} when status in [:consumed, :expired] -> {:error, :capability_expired}
      nil -> {:error, :capability_expired}
    end
  end
end
