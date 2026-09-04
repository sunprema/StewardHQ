defmodule Steward.Errors.UnfencedWrite do
  @moduledoc """
  Raised/added when a mutating action reaches `Steward.Changes.EnforceFencing`
  with no lease in changeset context — the write-side analogue of
  `{:error, :unborrowed_access}` (docs/tech_spec.md §4.4 v2.3 addendum;
  CLAUDE.md invariant 2).
  """

  use Splode.Error, fields: [:resource], class: :invalid

  def message(error) do
    "Attempted an unfenced write on #{inspect(error.resource)}: no lease/fencing token present in context"
  end
end
