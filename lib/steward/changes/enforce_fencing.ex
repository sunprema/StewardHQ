defmodule Steward.Changes.EnforceFencing do
  @moduledoc """
  Ash change enforcing version fencing on writes to a shadow resource
  (docs/tech_spec.md §4.2 implementation note: "an Ash change
  (Steward.Changes.EnforceFencing) attaches the conditional check
  (If-Match or equivalent) to the outgoing call and blocks the write if
  no token is present in context"; CLAUDE.md invariant 2, "no unfenced
  write").

  Expects the acting caller to have already acquired a `Steward.LeaseProvider`
  lease and placed it in changeset context as
  `%{steward: %{lease: lease}}`, where `lease` is exactly what
  `Steward.LeaseProvider.acquire/2` returned — this is a hand-wired call
  today; the Phase 3 `Steward.Resource` DSL is what will eventually inject
  this automatically the way it injects `borrow_token` witnessing.

  ## The lease is verified against its provider, not read out of context

  A lease in context is treated as a *claim*, not as evidence. Before the
  backend is called, the claim is checked against
  `Steward.LeaseProvider.current/1` for the lease's own `:key`: the
  provider must still be holding a lease with the same `:ref` and the same
  fencing `:token`. That closes the hole a context-only check leaves open,
  where a caller could hand in `%{token: 999, expires_at: <far future>}`
  and both pass the check *and* supply the fencing token sent to the
  backend — making the monotonic token caller-controlled, which is the one
  property fencing exists to guarantee.

  Verification happens inside the `before_action` hook, immediately before
  the backend call, rather than at changeset-build time: a lease that was
  valid when the changeset was assembled but expired before the write must
  not be allowed through. A malformed or absent lease is
  `Steward.Errors.UnfencedWrite`; a well-formed one the provider no longer
  recognises is `Steward.Errors.LeaseExpired`.

  A backend-side version mismatch surfaces as `Steward.Errors.StaleResource`
  (`{:error, :stale_resource, remote_state}` once unwrapped via
  `Steward.Errors.reason/1`).

  Options:
    * `:backend` (required) — module implementing `Steward.Backend`.
    * `:resource_id_attribute` (default `:external_id`) — attribute identifying
      the record to the backend.
    * `:version_attribute` (default `:version`).
    * `:sync_status_attribute` (default `:sync_status`).

  Requires `require_atomic? false` on the action: the backend call inside
  `before_action` cannot be expressed as a database expression.
  """

  use Ash.Resource.Change

  alias Ash.Resource.Info, as: ResourceInfo
  alias Steward.Errors.{LeaseExpired, StaleResource, UnfencedWrite}
  alias Steward.LeaseProvider

  @impl true
  def init(opts) do
    if is_nil(opts[:backend]) do
      {:error, "Steward.Changes.EnforceFencing requires a :backend module"}
    else
      {:ok,
       opts
       |> Keyword.put_new(:resource_id_attribute, :external_id)
       |> Keyword.put_new(:version_attribute, :version)
       |> Keyword.put_new(:sync_status_attribute, :sync_status)}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    # Fail fast on a wholly unfenced call without building the hook at
    # all; everything else is decided at write time in `fenced_write/3`.
    case get_in(changeset.context, [:steward, :lease]) do
      nil -> reject(changeset, UnfencedWrite)
      lease -> Ash.Changeset.before_action(changeset, &fenced_write(&1, opts, lease))
    end
  end

  defp fenced_write(changeset, opts, lease) do
    case verify_lease(lease) do
      # Note `verified`, not `lease`: the token sent to the backend is the
      # one read back from the provider, never the one that arrived in
      # context. They are equal by the time we get here — that is what
      # verification established — but taking the provider's copy means a
      # caller-supplied value can never reach the backend even if this
      # check is later loosened.
      {:ok, verified} -> write(changeset, opts, verified)
      {:error, :unfenced_write} -> reject(changeset, UnfencedWrite)
      {:error, :lease_expired} -> reject(changeset, LeaseExpired)
    end
  end

  defp reject(changeset, error_module) do
    Ash.Changeset.add_error(changeset, error_module.exception(resource: changeset.resource))
  end

  # A lease is only what `Steward.LeaseProvider.acquire/2` returned: the
  # provider for its own key must still be holding this exact ref, and
  # the fencing token travelling with it must be the one that provider
  # issued.
  @spec verify_lease(term()) ::
          {:ok, Steward.LeaseProvider.lease()}
          | {:error, :unfenced_write}
          | {:error, :lease_expired}
  defp verify_lease(%{key: key, ref: ref, token: token, expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      key |> LeaseProvider.current() |> match_current(ref, token)
    else
      {:error, :lease_expired}
    end
  end

  # Not the shape `acquire/2` returns at all — a hand-built map, or a
  # lease from before this contract. It cannot be checked, so it cannot
  # fence anything.
  defp verify_lease(_not_a_lease), do: {:error, :unfenced_write}

  defp match_current(%{ref: ref, token: token} = current, ref, token), do: {:ok, current}

  # The right lease, carrying the wrong fencing token: the value that
  # would reach the backend is not the one the provider issued, which is
  # precisely an unfenced write, not an expired one.
  defp match_current(%{ref: ref}, ref, _token), do: {:error, :unfenced_write}

  # No lease outstanding for this key, or it belongs to a later holder.
  defp match_current(_none_or_superseded, _ref, _token), do: {:error, :lease_expired}

  defp write(changeset, opts, lease) do
    resource_id = Ash.Changeset.get_attribute(changeset, opts[:resource_id_attribute])
    expected_version = Map.get(changeset.data, opts[:version_attribute])
    changes = writable_changes(changeset, opts)

    case opts[:backend].write(resource_id, changes, lease.token, expected_version) do
      {:ok, %{version: version, state: state}} ->
        reconciled = known_attribute_changes(changeset.resource, state)

        changeset
        |> Ash.Changeset.force_change_attributes(reconciled)
        |> Ash.Changeset.force_change_attribute(opts[:version_attribute], version)
        |> Ash.Changeset.force_change_attribute(opts[:sync_status_attribute], :synced)

      {:error, :stale_resource, remote_state} ->
        Ash.Changeset.add_error(
          changeset,
          StaleResource.exception(resource: changeset.resource, remote_state: remote_state)
        )

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, message: "backend write failed: #{inspect(reason)}")
    end
  end

  defp writable_changes(changeset, opts) do
    Map.drop(changeset.attributes, [opts[:version_attribute], opts[:sync_status_attribute]])
  end

  defp known_attribute_changes(resource, state) do
    attribute_names = resource |> ResourceInfo.attributes() |> MapSet.new(& &1.name)
    Map.take(state, MapSet.to_list(attribute_names))
  end
end
