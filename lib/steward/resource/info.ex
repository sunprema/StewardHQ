defmodule Steward.Resource.Info do
  @moduledoc """
  Introspection for the `Steward.Resource` Spark DSL extension
  (docs/tech_spec.md §6, §8 Phase 3).

  `use Spark.InfoGenerator` derives the option accessors (`steward_ownership/1`,
  `steward_locking/1`, ...) and the raw per-section entity listings
  (`steward/1`, `steward_state_machine/1`). The functions below are
  hand-written filters over those raw listings — the same pattern
  `AshOban.Info` uses on top of its own generated `oban_triggers/1` — since
  a single Spark section can hold more than one entity *type* (here,
  `capability`, `invariant`, and `idempotency` all live directly under
  `steward`).
  """

  use Spark.InfoGenerator, extension: Steward.Resource, sections: [:steward]

  alias Steward.Resource.{Capability, IdempotencyPolicy, Invariant, State, Transition}

  @doc "All `capability` entities declared on `resource`."
  @spec capabilities(Ash.Resource.t() | Spark.Dsl.t()) :: [Capability.t()]
  def capabilities(resource) do
    resource |> steward() |> Enum.filter(&match?(%Capability{}, &1))
  end

  @doc "The `capability` entity named `name`, or `nil`."
  @spec capability(Ash.Resource.t() | Spark.Dsl.t(), atom()) :: Capability.t() | nil
  def capability(resource, name) do
    Enum.find(capabilities(resource), &(&1.name == name))
  end

  @doc "All `invariant` entities declared on `resource`."
  @spec invariants(Ash.Resource.t() | Spark.Dsl.t()) :: [Invariant.t()]
  def invariants(resource) do
    resource |> steward() |> Enum.filter(&match?(%Invariant{}, &1))
  end

  @doc "The resource's `idempotency` policy, or `nil` if undeclared."
  @spec idempotency_policy(Ash.Resource.t() | Spark.Dsl.t()) :: IdempotencyPolicy.t() | nil
  def idempotency_policy(resource) do
    Enum.find(steward(resource), &match?(%IdempotencyPolicy{}, &1))
  end

  @doc "All `state` entities declared in the resource's `state_machine` block."
  @spec states(Ash.Resource.t() | Spark.Dsl.t()) :: [State.t()]
  def states(resource) do
    resource |> steward_state_machine() |> Enum.filter(&match?(%State{}, &1))
  end

  @doc "The name of the state flagged `initial?: true`, or `nil`."
  @spec initial_state(Ash.Resource.t() | Spark.Dsl.t()) :: atom() | nil
  def initial_state(resource) do
    case Enum.find(states(resource), & &1.initial?) do
      nil -> nil
      state -> state.name
    end
  end

  @doc "All `transition` entities declared in the resource's `state_machine` block."
  @spec transitions(Ash.Resource.t() | Spark.Dsl.t()) :: [Transition.t()]
  def transitions(resource) do
    resource |> steward_state_machine() |> Enum.filter(&match?(%Transition{}, &1))
  end

  @doc "The `transition` entity named `name`, or `nil` if `name` isn't a state transition."
  @spec transition(Ash.Resource.t() | Spark.Dsl.t(), atom()) :: Transition.t() | nil
  def transition(resource, name) do
    Enum.find(transitions(resource), &(&1.name == name))
  end
end
