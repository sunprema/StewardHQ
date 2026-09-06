defmodule Steward.Errors.UnborrowedAccess do
  @moduledoc """
  Raised/added when an action reaches `Steward.Resource.Validations.RequireWitness`
  without a *verifiable* `borrow_token` in changeset/query/input context —
  the read-side and general-access analogue of `Steward.Errors.UnfencedWrite`
  (docs/tech_spec.md §4.1 "Witness Pattern", §4.4; CLAUDE.md invariant 1).

  Deliberately one reason for four situations — no token, a fabricated
  token, a token whose borrow has since been released, and a token
  granted to a different process or a different resource. They are the
  same fact from the resource's point of view: the caller cannot prove
  custody. Distinguishing them in the error would tell a probing caller
  which guess got closer.
  """

  use Splode.Error, fields: [:resource], class: :invalid

  def message(error) do
    "Attempted unwitnessed access to #{inspect(error.resource)}: context carries no borrow_token, or none this process currently holds on this resource"
  end
end
