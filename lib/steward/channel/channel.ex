defmodule Steward.Channel.Channel do
  @moduledoc """
  Target struct for a `channel` DSL entity (docs/tech_spec.md §3.4): a
  bounded, typed transport for capability/task movement across an agent
  process boundary.
  """

  defstruct name: nil,
            capacity: 100,
            overflow: :reject,
            overflow_timeout: nil,
            allow_delegation: [],
            require_intent: false,
            messages: [],
            __identifier__: nil,
            __spark_metadata__: nil

  @type t :: %__MODULE__{
          name: atom(),
          capacity: pos_integer(),
          overflow: :block | :reject,
          overflow_timeout: pos_integer() | nil,
          allow_delegation: [atom()],
          require_intent: boolean(),
          messages: [Steward.Channel.Message.t()]
        }
end
