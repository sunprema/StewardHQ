defmodule Steward.Resource.State do
  @moduledoc """
  Target struct for a `state` DSL entity inside a resource's
  `state_machine` block (docs/tech_spec.md §6).
  """

  defstruct name: nil, initial?: false, __identifier__: nil, __spark_metadata__: nil

  @type t :: %__MODULE__{name: atom(), initial?: boolean()}
end
