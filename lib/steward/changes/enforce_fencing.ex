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
  `%{steward: %{lease: %{token: fencing_token, expires_at: dt}}}` — this
  is a hand-wired call today; the Phase 3 `Steward.Resource` DSL is what
  will eventually inject this automatically the way it injects
  `borrow_token` witnessing.

  A missing or expired lease is rejected *before* the backend is ever
  called (`Steward.Errors.UnfencedWrite` / `Steward.Errors.LeaseExpired`)
  — this is what makes invariant 2 real rather than advisory. Otherwise a
  `before_action` hook calls `opts[:backend].write/4` with the lease's
  fencing token and the record's current version; a backend-side version
  mismatch surfaces as `Steward.Errors.StaleResource` (`{:error,
  :stale_resource, remote_state}` once unwrapped via `Steward.Errors.reason/1`).

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
    resource = changeset.resource

    case get_in(changeset.context, [:steward, :lease]) do
      nil ->
        Ash.Changeset.add_error(changeset, UnfencedWrite.exception(resource: resource))

      %{expires_at: expires_at} = lease ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          attach_backend_write(changeset, opts, lease)
        else
          Ash.Changeset.add_error(changeset, LeaseExpired.exception(resource: resource))
        end
    end
  end

  defp attach_backend_write(changeset, opts, lease) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      resource_id = Ash.Changeset.get_attribute(changeset, opts[:resource_id_attribute])
      expected_version = Map.get(changeset.data, opts[:version_attribute])
      changes = writable_changes(changeset, opts)

      case opts[:backend].write(resource_id, changes, lease.token, expected_version) do
        {:ok, %{version: version, state: state}} ->
          changeset
          |> Ash.Changeset.force_change_attributes(
            known_attribute_changes(changeset.resource, state)
          )
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
    end)
  end

  defp writable_changes(changeset, opts) do
    Map.drop(changeset.attributes, [opts[:version_attribute], opts[:sync_status_attribute]])
  end

  defp known_attribute_changes(resource, state) do
    attribute_names = resource |> ResourceInfo.attributes() |> MapSet.new(& &1.name)
    Map.take(state, MapSet.to_list(attribute_names))
  end
end
