defmodule Steward.Resource.Capability do
  @moduledoc """
  Target struct for a `capability` DSL entity (docs/tech_spec.md §6, §3.1,
  §4.4).

  A capability names a right an agent can be granted over a stewarded
  resource — typically corresponding 1:1 with an Ash action name on the
  same resource. `Steward.PlanValidator` reads `:mode` to compute
  canonical borrow order, `:requires_freshness` to reject stale plan
  steps, and `:reversibility` to enforce the irreversible-last ordering
  rule (CLAUDE.md invariant 6).
  """

  defstruct name: nil,
            mode: :exclusive,
            consumption: :reusable,
            lifetime: :plan,
            requires_freshness: :any,
            reversibility: :undoable,
            undo: nil,
            compensate: nil,
            __identifier__: nil,
            __spark_metadata__: nil

  @type t :: %__MODULE__{
          name: atom(),
          mode: :shared | :exclusive,
          consumption: :linear | :reusable,
          lifetime: :plan | :step,
          requires_freshness: :any | {:max_age, pos_integer()},
          reversibility: :undoable | :compensatable | :irreversible,
          undo: atom() | nil,
          compensate: atom() | nil
        }
end
