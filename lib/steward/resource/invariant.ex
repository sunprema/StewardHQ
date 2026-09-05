defmodule Steward.Resource.Invariant do
  @moduledoc """
  Target struct for an `invariant` DSL entity (docs/tech_spec.md §6).

  Captures a named `Ash.Expr` predicate that must hold for the resource
  (e.g. `amount_paid <= total_amount`). Part of the compiled Resource
  Safety Graph (`Steward.Resource.SafetyGraph`) for introspection; static
  enforcement in the Plan Validator is not part of Phase 3's deliverables
  (docs/tech_spec.md §8) and is intentionally left for a later phase —
  see CLAUDE.md: "don't build ahead of the current phase."
  """

  defstruct name: nil, expr: nil, __identifier__: nil, __spark_metadata__: nil

  @type t :: %__MODULE__{name: atom(), expr: Ash.Expr.t()}
end
