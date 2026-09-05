defmodule Steward.PlanValidatorTest do
  @moduledoc """
  Phase 3 definition-of-done coverage for `Steward.PlanValidator`
  (docs/tech_spec.md §7 "Static analysis", §8 Phase 3): state-machine
  simulation, freshness checks, reversibility ordering, and canonical
  borrow-order sorting — against the real compiled Resource Safety Graph
  of `Steward.Test.Examples.Invoice`, not a hand-rolled stand-in.
  """

  use ExUnit.Case, async: true

  alias Steward.PlanValidator
  alias Steward.Test.Examples.Invoice

  defp resource_id, do: Ecto.UUID.generate()

  describe "state-machine simulation" do
    test "a plan that follows the declared transitions in order is valid" do
      id = resource_id()

      plan = [
        %{id: 1, resource: Invoice, resource_id: id, action: :approve},
        %{
          id: 2,
          resource: Invoice,
          resource_id: id,
          action: :pay,
          observed_at: DateTime.utc_now()
        }
      ]

      assert :ok = PlanValidator.validate(plan)
    end

    test "skipping a state (pay before approve) fails as :invalid_transition with the current state" do
      id = resource_id()
      plan = [%{id: 1, resource: Invoice, resource_id: id, action: :pay}]

      assert {:error, :invalid_transition, :draft} = PlanValidator.validate(plan)
    end

    test "an explicit initial-state override is respected" do
      id = resource_id()

      plan = [
        %{
          id: 1,
          resource: Invoice,
          resource_id: id,
          action: :pay,
          observed_at: DateTime.utc_now()
        }
      ]

      assert {:error, :invalid_transition, :draft} = PlanValidator.validate(plan)

      assert :ok =
               PlanValidator.validate(plan,
                 initial_states: %{{Invoice, id} => :approved}
               )
    end

    test "a step whose action isn't a state transition (e.g. :read) doesn't change simulated state" do
      id = resource_id()

      plan = [
        %{id: 1, resource: Invoice, resource_id: id, action: :read},
        %{id: 2, resource: Invoice, resource_id: id, action: :approve}
      ]

      assert :ok = PlanValidator.validate(plan)
    end
  end

  describe "freshness checks" do
    test "a step against a freshness-bound capability with no :observed_at is rejected as stale" do
      id = resource_id()

      plan = [
        %{id: 1, resource: Invoice, resource_id: id, action: :approve},
        %{id: 2, resource: Invoice, resource_id: id, action: :pay}
      ]

      assert {:error, :stale_resource, %{step: 2, reason: :not_observed}} =
               PlanValidator.validate(plan)
    end

    test "a step observed too long ago is rejected as stale, within budget succeeds" do
      id = resource_id()
      now = DateTime.utc_now()

      too_old = [
        %{id: 1, resource: Invoice, resource_id: id, action: :approve},
        %{
          id: 2,
          resource: Invoice,
          resource_id: id,
          action: :pay,
          observed_at: DateTime.add(now, -31, :second)
        }
      ]

      assert {:error, :stale_resource, %{step: 2, age_ms: age_ms}} =
               PlanValidator.validate(too_old, now: now)

      assert age_ms > 30_000

      within_budget = [
        %{id: 1, resource: Invoice, resource_id: id, action: :approve},
        %{
          id: 2,
          resource: Invoice,
          resource_id: id,
          action: :pay,
          observed_at: DateTime.add(now, -5, :second)
        }
      ]

      assert :ok = PlanValidator.validate(within_budget, now: now)
    end

    test "capabilities with no freshness requirement (e.g. :read) never need :observed_at" do
      id = resource_id()
      plan = [%{id: 1, resource: Invoice, resource_id: id, action: :read}]

      assert :ok = PlanValidator.validate(plan)
    end
  end

  describe "reversibility ordering (CLAUDE.md invariant 6)" do
    test "an irreversible step before a fallible one on another resource is rejected" do
      id1 = resource_id()
      id2 = resource_id()

      plan = [
        %{id: 1, resource: Invoice, resource_id: id1, action: :notify},
        %{id: 2, resource: Invoice, resource_id: id2, action: :approve}
      ]

      assert {:error, :irreversible_before_fallible, 1} = PlanValidator.validate(plan)
    end

    test "fallible steps before an irreversible one are fine" do
      id1 = resource_id()
      id2 = resource_id()

      plan = [
        %{id: 1, resource: Invoice, resource_id: id2, action: :approve},
        %{id: 2, resource: Invoice, resource_id: id1, action: :notify}
      ]

      assert :ok = PlanValidator.validate(plan)
    end

    test "back-to-back irreversible steps are fine, but a fallible step after either is rejected" do
      id1 = resource_id()
      id2 = resource_id()
      id3 = resource_id()

      plan = [
        %{id: 1, resource: Invoice, resource_id: id1, action: :notify},
        %{id: 2, resource: Invoice, resource_id: id2, action: :notify},
        %{id: 3, resource: Invoice, resource_id: id3, action: :approve}
      ]

      assert {:error, :irreversible_before_fallible, 1} = PlanValidator.validate(plan)
    end
  end

  describe "canonical_borrow_order/1" do
    test "sorts distinct resources into canonical resource_type:id order" do
      plan = [
        %{id: 1, resource: Invoice, resource_id: "b", action: :read},
        %{id: 2, resource: Invoice, resource_id: "a", action: :approve}
      ]

      assert PlanValidator.canonical_borrow_order(plan) == [
               {"Steward.Test.Examples.Invoice:a", :exclusive},
               {"Steward.Test.Examples.Invoice:b", :shared}
             ]
    end

    test "the same resource appearing under multiple modes is deduped to its strongest mode" do
      plan = [
        %{id: 1, resource: Invoice, resource_id: "a", action: :read},
        %{id: 2, resource: Invoice, resource_id: "a", action: :approve}
      ]

      assert PlanValidator.canonical_borrow_order(plan) == [
               {"Steward.Test.Examples.Invoice:a", :exclusive}
             ]
    end
  end
end
