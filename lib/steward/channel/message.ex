defmodule Steward.Channel.Message do
  @moduledoc """
  Target struct for a `message` DSL entity inside a `channel` block
  (docs/tech_spec.md §3.4).

  `:schema` names the module describing this message's payload shape
  (e.g. an Ash embedded resource, per the spec's own example) — kept for
  introspection and documentation today. Runtime payload validation
  against `:schema` is not implemented in v1 (see `Steward.Channel`'s
  moduledoc "Deviations from the spec's illustrative syntax"); it is the
  "full DSL surface" the roadmap (§8 Phase 5) explicitly defers.
  """

  defstruct name: nil, schema: nil, __identifier__: nil, __spark_metadata__: nil

  @type t :: %__MODULE__{name: atom(), schema: module() | nil}
end
