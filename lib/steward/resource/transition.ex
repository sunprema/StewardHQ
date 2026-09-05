defmodule Steward.Resource.Transition do
  @moduledoc """
  Target struct for a `transition` DSL entity inside a resource's
  `state_machine` block (docs/tech_spec.md §6).

  `:name` matches the capability/action name that performs this
  transition; `Steward.PlanValidator` looks transitions up by that name
  to simulate a plan against the declared state graph.
  """

  defstruct name: nil, from: nil, to: nil, __identifier__: nil, __spark_metadata__: nil

  @type t :: %__MODULE__{name: atom(), from: atom(), to: atom()}
end
