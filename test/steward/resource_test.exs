defmodule Steward.ResourceTest do
  @moduledoc """
  Phase 3 definition-of-done coverage (docs/tech_spec.md §8): the
  `Steward.Resource` Spark extension compiles a resource's `steward do
  ... end` block into an introspectable Resource Safety Graph
  (docs/tech_spec.md §5, §6; CLAUDE.md architecture map).
  """

  use ExUnit.Case, async: true

  alias Steward.Resource.{Info, SafetyGraph}
  alias Steward.Test.Examples.Invoice

  describe "Steward.Resource.Info" do
    test "exposes the declared ownership attribute and locking tier" do
      assert Info.steward_ownership!(Invoice) == :account_id
      assert Info.steward_locking!(Invoice) == :conditional_write
    end

    test "exposes declared capabilities with their laws" do
      assert %{mode: :shared, reversibility: :undoable} = Info.capability(Invoice, :read)

      assert %{
               mode: :exclusive,
               consumption: :linear,
               reversibility: :compensatable,
               compensate: :refund,
               requires_freshness: {:max_age, 30_000}
             } = Info.capability(Invoice, :pay)

      assert Info.capability(Invoice, :nonexistent) == nil
    end

    test "exposes the declared state machine" do
      assert Info.initial_state(Invoice) == :draft

      assert Enum.map(Info.states(Invoice), & &1.name) |> Enum.sort() == [
               :approved,
               :draft,
               :paid
             ]

      assert %{from: :draft, to: :approved} = Info.transition(Invoice, :approve)
      assert %{from: :approved, to: :paid} = Info.transition(Invoice, :pay)
      assert Info.transition(Invoice, :read) == nil
    end

    test "exposes the declared idempotency policy" do
      assert %{mode: :header, key: "Idempotency-Key"} = Info.idempotency_policy(Invoice)
    end
  end

  describe "Steward.Resource.SafetyGraph.build/1" do
    test "assembles the full compiled graph for a resource" do
      graph = SafetyGraph.build(Invoice)

      assert graph.resource == Invoice
      assert graph.ownership == :account_id
      assert graph.locking == :conditional_write
      assert graph.initial_state == :draft
      assert length(graph.capabilities) == 4
      assert length(graph.states) == 3
      assert length(graph.transitions) == 2
      assert %{mode: :header} = graph.idempotency
    end
  end
end
