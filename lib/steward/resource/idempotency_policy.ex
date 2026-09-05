defmodule Steward.Resource.IdempotencyPolicy do
  @moduledoc """
  Target struct for the (singleton) `idempotency` DSL entity
  (docs/tech_spec.md §6, §4.2 "Idempotency keys").

  Named `IdempotencyPolicy` rather than `Idempotency` to avoid colliding
  with `Steward.Idempotency`, the Phase 2 key-generation/injection module
  this policy's `:mode` and `:key` are meant to drive once a Phase 4 saga
  step calls `Steward.Idempotency.inject/4` automatically.
  """

  defstruct mode: :none, key: nil, __spark_metadata__: nil

  @type t :: %__MODULE__{mode: Steward.Idempotency.mode(), key: String.t() | nil}
end
