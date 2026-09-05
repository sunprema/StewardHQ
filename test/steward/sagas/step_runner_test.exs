defmodule Steward.Sagas.StepRunnerTest do
  @moduledoc """
  Direct coverage of `Steward.Sagas.StepRunner.compensate/4`'s capability
  disposition decision (CLAUDE.md invariant 3, docs/tech_spec.md §4.3):
  a function of the structured error taxonomy, tested directly against
  each reason rather than only through a full saga run (see
  `Steward.SagaExecutorTest` for the end-to-end undo path).
  """

  use Steward.DataCase, async: true

  require Ash.Query

  alias Steward.Sagas
  alias Steward.Sagas.StepRunner
  alias Steward.Test.Examples
  alias Steward.Test.Examples.Invoice

  defp create_invoice! do
    Examples.create_invoice!(Ecto.UUID.generate(), Decimal.new(100),
      context: %{steward: %{borrow_token: make_ref()}}
    )
  end

  defp saga_step_for(saga_id, step_id) do
    Sagas.SagaStep
    |> Ash.Query.filter(saga_id == ^saga_id and step_id == ^step_id)
    |> Ash.read_one!()
  end

  describe "compensate/4" do
    test ":stale_resource survives: retries and records disposition :survived" do
      invoice = create_invoice!()
      {:ok, saga} = Sagas.create_saga([])
      step = %{id: 1, resource: Invoice, resource_id: invoice.id, action: :pay}
      opts = [plan_step: step, saga_id: saga.id, borrow_tokens: %{}]

      assert :retry = StepRunner.compensate({:stale_resource, %{}}, %{}, %{}, opts)

      saga_step = saga_step_for(saga.id, "1")
      assert saga_step.status == :failed
      assert saga_step.disposition == :survived
    end

    test "any other reason (e.g. :invalid_transition) is dropped: no retry, disposition :dropped" do
      invoice = create_invoice!()
      {:ok, saga} = Sagas.create_saga([])
      step = %{id: 2, resource: Invoice, resource_id: invoice.id, action: :pay}
      opts = [plan_step: step, saga_id: saga.id, borrow_tokens: %{}]

      assert {:error, :invalid_transition} =
               StepRunner.compensate(:invalid_transition, %{}, %{}, opts)

      saga_step = saga_step_for(saga.id, "2")
      assert saga_step.status == :failed
      assert saga_step.disposition == :dropped
    end
  end
end
