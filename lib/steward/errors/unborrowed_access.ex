defmodule Steward.Errors.UnborrowedAccess do
  @moduledoc """
  Raised/added when an action reaches `Steward.Resource.Validations.RequireWitness`
  with no `borrow_token` in changeset/query/input context — the read-side
  and general-access analogue of `Steward.Errors.UnfencedWrite`
  (docs/tech_spec.md §4.1 "Witness Pattern", §4.4; CLAUDE.md invariant 1).
  """

  use Splode.Error, fields: [:resource], class: :invalid

  def message(error) do
    "Attempted unwitnessed access to #{inspect(error.resource)}: no borrow_token present in context"
  end
end
