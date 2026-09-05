defmodule Steward.SagaExecutorTest do
  @moduledoc """
  Phase 4 definition-of-done coverage (docs/tech_spec.md §8): Reactor
  integration (run/compensate/undo), plan-scoped borrows, capability
  disposition by error type, and durable saga state — end to end against
  the real `Steward.Test.Examples.Invoice` resource and a real Postgres
  `Steward.Sagas.Saga`/`Steward.Sagas.SagaStep`, not stand-ins.
  """

  use Steward.DataCase, async: true

  require Ash.Query

  alias Steward.SagaExecutor
  alias Steward.Sagas
  alias Steward.Test.Examples
  alias Steward.Test.Examples.Invoice

  defp account_id, do: Ecto.UUID.generate()

  defp create_invoice!(total \\ Decimal.new(100)) do
    Examples.create_invoice!(account_id(), total,
      context: %{steward: %{borrow_token: make_ref()}}
    )
  end

  defp last_saga!,
    do: Sagas.Saga |> Ash.Query.sort(inserted_at: :desc) |> Ash.read!() |> List.first()

  defp saga_steps(saga_id) do
    Sagas.SagaStep
    |> Ash.Query.filter(saga_id == ^saga_id)
    |> Ash.Query.sort(:inserted_at)
    |> Ash.read!()
  end

  describe "execute/2 happy path" do
    test "runs a multi-step plan in order and persists a completed saga" do
      invoice = create_invoice!()

      plan = [
        %{id: 1, resource: Invoice, resource_id: invoice.id, action: :approve},
        %{
          id: 2,
          resource: Invoice,
          resource_id: invoice.id,
          action: :pay,
          args: %{amount_paid: Decimal.new(100)},
          observed_at: DateTime.utc_now()
        }
      ]

      assert {:ok, result} = SagaExecutor.execute(plan)
      assert result.status == :paid
      assert Decimal.equal?(result.amount_paid, Decimal.new(100))

      assert {:ok, updated} = Examples.get_invoice(invoice.id)
      assert updated.status == :paid

      saga = last_saga!()
      assert saga.status == :completed
      assert length(saga.plan) == 2

      steps = saga_steps(saga.id)
      assert Enum.map(steps, & &1.status) == [:succeeded, :succeeded]
      assert Enum.map(steps, & &1.disposition) == [nil, :consumed]
    end

    test "an invalid plan is rejected before any saga row or borrow is created" do
      invoice = create_invoice!()

      plan = [
        %{
          id: 1,
          resource: Invoice,
          resource_id: invoice.id,
          action: :pay,
          observed_at: DateTime.utc_now()
        }
      ]

      before_count = Sagas.Saga |> Ash.read!() |> length()

      assert {:error, :invalid_transition, :draft} = SagaExecutor.execute(plan)

      assert ^before_count = Sagas.Saga |> Ash.read!() |> length()

      assert %{shared: [], exclusive: nil, queue_length: 0} =
               Steward.ResourceServer.borrows({Invoice, invoice.id})
    end
  end

  describe "capability disposition and undo (CLAUDE.md invariants 3 and 6)" do
    test "a step failing non-retryably is dropped, and the earlier undoable step is undone" do
      invoice = create_invoice!()

      plan = [
        %{id: 1, resource: Invoice, resource_id: invoice.id, action: :approve},
        %{id: 2, resource: Invoice, resource_id: invoice.id, action: :nonexistent_action}
      ]

      assert {:error, _reason} = SagaExecutor.execute(plan)

      saga = last_saga!()
      assert saga.status == :failed

      steps = saga_steps(saga.id)
      assert %{status: :undone} = Enum.find(steps, &(&1.step_id == "1"))
      assert %{status: :failed, disposition: :dropped} = Enum.find(steps, &(&1.step_id == "2"))

      # :approve's declared undo (:unapprove) ran, rolling the invoice back
      assert {:ok, rolled_back} = Examples.get_invoice(invoice.id)
      assert rolled_back.status == :draft
    end
  end
end
