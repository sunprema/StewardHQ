defmodule Steward.Errors do
  @moduledoc """
  Adapter between Ash's error idiom (`{:error, %Ash.Error.Invalid{}}`, per
  the `ash` framework's own usage rules) and the flat structured-tuple
  contract CLAUDE.md and docs/tech_spec.md §4.4 promise callers:
  `{:error, reason_atom, context}`.

  `Steward.Changes.EnforceFencing` adds proper Ash/Splode errors
  (`Steward.Errors.UnfencedWrite`, `LeaseExpired`, `StaleResource`) to the
  changeset, which Ash wraps in `Ash.Error.Invalid` when the action
  fails. `reason/1` unwraps that back into the taxonomy's flat shape at
  the Steward call-site boundary.
  """

  alias Steward.Errors.{LeaseExpired, StaleResource, UnfencedWrite}

  @doc """
  Extracts the spec §4.4 flat error tuple from an `Ash.Error.Invalid`
  (or a bare Steward error struct). Falls back to
  `{:error, :invalid, error}` for anything else Ash surfaced that isn't
  one of ours.
  """
  @spec reason(Ash.Error.Invalid.t() | struct()) ::
          {:error, :unfenced_write}
          | {:error, :lease_expired}
          | {:error, :stale_resource, map()}
          | {:error, :invalid, term()}
  def reason(%Ash.Error.Invalid{errors: [first | _rest]}), do: reason(first)
  def reason(%UnfencedWrite{}), do: {:error, :unfenced_write}
  def reason(%LeaseExpired{}), do: {:error, :lease_expired}

  def reason(%StaleResource{remote_state: remote_state}),
    do: {:error, :stale_resource, remote_state}

  def reason(other), do: {:error, :invalid, other}
end
