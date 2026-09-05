defmodule Steward.Resource.SafetyGraph do
  @moduledoc """
  Assembles a resource's compiled `Steward.Resource` DSL into the single
  struct named throughout docs/tech_spec.md as the "Resource Safety
  Graph" (§5 "Control plane: Spark DSL defines the laws; compiled into a
  Resource Safety Graph"; §8 Phase 3).

  This is a plain, static snapshot for introspection and for
  `Steward.PlanValidator` to consume — building one does not query a
  database or start any process. `Steward.Resource.Info` remains the
  source of truth; this struct just gathers its answers into one value
  instead of requiring several separate calls.
  """

  alias Steward.Resource.{Capability, IdempotencyPolicy, Info, Invariant, State, Transition}

  defstruct resource: nil,
            ownership: nil,
            locking: :serialized,
            capabilities: [],
            invariants: [],
            states: [],
            transitions: [],
            initial_state: nil,
            idempotency: nil

  @type t :: %__MODULE__{
          resource: module(),
          ownership: atom(),
          locking: :native_lease | :conditional_write | :serialized,
          capabilities: [Capability.t()],
          invariants: [Invariant.t()],
          states: [State.t()],
          transitions: [Transition.t()],
          initial_state: atom() | nil,
          idempotency: IdempotencyPolicy.t() | nil
        }

  @doc "Builds the Resource Safety Graph for a resource using the `Steward.Resource` extension."
  @spec build(module()) :: t()
  def build(resource) do
    %__MODULE__{
      resource: resource,
      ownership: Info.steward_ownership!(resource),
      locking: Info.steward_locking!(resource),
      capabilities: Info.capabilities(resource),
      invariants: Info.invariants(resource),
      states: Info.states(resource),
      transitions: Info.transitions(resource),
      initial_state: Info.initial_state(resource),
      idempotency: Info.idempotency_policy(resource)
    }
  end
end
