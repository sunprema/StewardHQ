defmodule Steward.LeaseProvider do
  @moduledoc """
  Authoritative, backend-standin lease lifecycle: acquire / renew / release /
  expire, with monotonically increasing fencing tokens (docs/tech_spec.md
  §3.2, §8 Phase 2).

  This is the second, authoritative tier of the two-tier arbitration
  described in the spec: `Steward.ResourceServer` is the cheap local tier
  that stops StewardHQ's own agents from requesting conflicting leases;
  this module stands in for the real backend lease service (native API
  lease, Redis, Zookeeper, ...) that a production deployment would call
  instead. Per CLAUDE.md's architecture map, it is deliberately a hardcoded
  v1 GenServer implementation, not a pluggable `LeaseProvider` behaviour —
  that abstraction is designed-for but deferred (spec §9).

  One GenServer per `resource_id`, registered via
  `Steward.Registry.via_tuple({:lease, resource_id})` — namespaced so a
  lease and a local borrow on the same `resource_id` never collide in the
  shared `Steward.Registry`.

  Expiry is TTL-timer-based only (`Process.send_after`), deliberately
  *not* `Process.monitor`-based like `Steward.ResourceServer`: a real
  backend lease service has no visibility into a BEAM process crashing.
  This is the honest two-tier distinction in practice — a crashed holder's
  local borrow releases instantly, but its backend lease survives until
  TTL, and a competing `acquire/2` correctly sees `{:error, :lease_held}`
  until then.

  Fencing-token durability is a known v1 limitation: the monotonic counter
  lives in this GenServer's state, so a supervisor restart resets it. A
  real backend lease service would persist its own counter.
  """

  use GenServer

  @default_ttl 10_000
  @default_max_duration 60_000

  defstruct resource_id: nil,
            token: 0,
            lease: nil

  ## Public API

  def start_link(resource_id) do
    GenServer.start_link(__MODULE__, resource_id, name: via(resource_id))
  end

  def child_spec(resource_id) do
    %{
      id: {__MODULE__, resource_id},
      start: {__MODULE__, :start_link, [resource_id]},
      restart: :transient
    }
  end

  @typedoc """
  A lease as handed to callers. Carries `:key` — the `resource_id` this
  provider was started for — so any downstream consumer (notably
  `Steward.Changes.EnforceFencing`) can re-verify the lease against this
  authority instead of trusting the values it was handed.
  """
  @type lease :: %{
          token: pos_integer(),
          ref: reference(),
          expires_at: DateTime.t(),
          key: term()
        }

  @doc """
  Acquires a lease on `resource_id`. Returns `{:error, :lease_held}` if
  another lease is currently outstanding (not yet expired or released) —
  the backend tier does not queue; callers decide whether to retry.

  `opts`: `:ttl` in ms (default #{@default_ttl}).
  """
  @spec acquire(term(), keyword()) :: {:ok, lease()} | {:error, :lease_held}
  def acquire(resource_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    {:ok, pid} = Steward.LeaseProviderSupervisor.ensure_started(resource_id)
    GenServer.call(pid, {:acquire, ttl})
  end

  @doc """
  Renews an outstanding lease, extending `expires_at` by `:ttl` (same
  fencing token). Enforces the hard renewal ceiling from spec §3.2
  ("bounded by a hard maximum so a stuck agent cannot hold forever"):
  once `opts[:max_duration]` (default #{@default_max_duration}ms,
  measured from the original `acquire/2`) would be exceeded, the lease is
  force-expired and `{:error, :lease_expired}` is returned. The same error
  is returned if `lease_ref` no longer matches the current lease (it
  already expired, or was never valid).
  """
  @spec renew(term(), reference(), keyword()) :: {:ok, lease()} | {:error, :lease_expired}
  def renew(resource_id, lease_ref, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    max_duration = Keyword.get(opts, :max_duration, @default_max_duration)

    case Steward.Registry.whereis({:lease, resource_id}) do
      {:ok, pid} -> GenServer.call(pid, {:renew, lease_ref, ttl, max_duration})
      :error -> {:error, :lease_expired}
    end
  end

  @doc "Releases a lease. Safe to call more than once."
  @spec release(term(), reference()) :: :ok | {:error, :not_leased}
  def release(resource_id, lease_ref) do
    case Steward.Registry.whereis({:lease, resource_id}) do
      {:ok, pid} -> GenServer.call(pid, {:release, lease_ref})
      :error -> {:error, :not_leased}
    end
  end

  @doc "Introspection helper for tests/tooling: the current lease, if any (expired leases read as none)."
  @spec current(term()) :: lease() | nil
  def current(resource_id) do
    case Steward.Registry.whereis({:lease, resource_id}) do
      {:ok, pid} -> GenServer.call(pid, :current)
      :error -> nil
    end
  end

  @doc false
  def via(resource_id), do: Steward.Registry.via_tuple({:lease, resource_id})

  ## GenServer callbacks

  @impl true
  def init(resource_id) do
    {:ok, %__MODULE__{resource_id: resource_id}}
  end

  @impl true
  def handle_call({:acquire, ttl}, _from, state) do
    if held?(state) do
      {:reply, {:error, :lease_held}, state}
    else
      token = state.token + 1
      lease = new_lease(token, ttl, System.monotonic_time(:millisecond))
      state = %{state | token: token, lease: lease}
      {:reply, {:ok, public_lease(state, lease)}, state}
    end
  end

  def handle_call({:renew, lease_ref, ttl, max_duration}, _from, state) do
    cond do
      not held?(state) or state.lease.ref != lease_ref ->
        {:reply, {:error, :lease_expired}, state}

      System.monotonic_time(:millisecond) - state.lease.acquired_at + ttl > max_duration ->
        Process.cancel_timer(state.lease.timer_ref)
        {:reply, {:error, :lease_expired}, %{state | lease: nil}}

      true ->
        lease = %{state.lease | expires_at: DateTime.add(DateTime.utc_now(), ttl, :millisecond)}
        Process.cancel_timer(lease.timer_ref)
        timer_ref = Process.send_after(self(), {:expire, lease_ref}, ttl)
        lease = %{lease | timer_ref: timer_ref}
        {:reply, {:ok, public_lease(state, lease)}, %{state | lease: lease}}
    end
  end

  def handle_call({:release, lease_ref}, _from, state) do
    if held?(state) and state.lease.ref == lease_ref do
      Process.cancel_timer(state.lease.timer_ref)
      {:reply, :ok, %{state | lease: nil}}
    else
      {:reply, {:error, :not_leased}, state}
    end
  end

  def handle_call(:current, _from, state) do
    reply = if held?(state), do: public_lease(state, state.lease), else: nil
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:expire, lease_ref}, state) do
    if held?(state) and state.lease.ref == lease_ref do
      {:noreply, %{state | lease: nil}}
    else
      {:noreply, state}
    end
  end

  ## Internal

  defp held?(state), do: not is_nil(state.lease)

  defp new_lease(token, ttl, now_monotonic) do
    ref = make_ref()
    timer_ref = Process.send_after(self(), {:expire, ref}, ttl)

    %{
      token: token,
      ref: ref,
      expires_at: DateTime.add(DateTime.utc_now(), ttl, :millisecond),
      acquired_at: now_monotonic,
      timer_ref: timer_ref
    }
  end

  defp public_lease(state, lease) do
    lease |> Map.take([:token, :ref, :expires_at]) |> Map.put(:key, state.resource_id)
  end
end
