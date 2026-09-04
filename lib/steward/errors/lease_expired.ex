defmodule Steward.Errors.LeaseExpired do
  @moduledoc """
  Raised/added when `Steward.Changes.EnforceFencing` finds a lease in
  context whose `expires_at` has already passed (docs/tech_spec.md §4.4
  v2.3 addendum, distinct from `:capability_expired`).
  """

  use Splode.Error, fields: [:resource], class: :invalid

  def message(error) do
    "Attempted a write on #{inspect(error.resource)} with an expired lease"
  end
end
