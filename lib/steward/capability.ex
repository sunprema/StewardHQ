defmodule Steward.Capability do
  @moduledoc """
  A linear capability token (docs/tech_spec.md §3.1 `own`): "a consumable
  token with move semantics." A plain, immutable runtime value — never
  persisted, never an Ash resource — matching the spec's framing that
  capabilities are plan-scoped, in-memory rights, not durable state.

  `Steward.CapabilityRegistry` is the single source of truth for a given
  `:ref`'s validity; this struct is just the value agents pass around.
  Holding a `%Steward.Capability{}` proves nothing by itself — every
  consumer must call `Steward.CapabilityRegistry.use_capability/1` (or
  `move/2`) to have its validity actually checked, the same way a
  `borrow_token` proves nothing without `Steward.ResourceServer` behind
  it.
  """

  @enforce_keys [:ref, :resource, :resource_id, :name, :consumption]
  defstruct [:ref, :resource, :resource_id, :name, :consumption]

  @type t :: %__MODULE__{
          ref: reference(),
          resource: module(),
          resource_id: term(),
          name: atom(),
          consumption: :linear | :reusable
        }
end
