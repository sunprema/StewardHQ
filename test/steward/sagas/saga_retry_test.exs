defmodule Steward.Sagas.SagaRetryTest do
  @moduledoc """
  Phase 4 definition-of-done coverage for the persistent retry queue and
  dead-letter escalation (docs/tech_spec.md §4.3, §8 Phase 4):
  `Steward.Sagas.Saga`'s `:retry` action — what the `AshOban` trigger's
  worker calls — re-invokes `Steward.SagaExecutor.resume/1` against the
  saga's own persisted, `Steward.Sagas.PlanCodec`-encoded plan, and
  escalates to `:dead_letter` once `:attempts` reaches the ceiling,
  rather than relying on Oban's own job-retry exhaustion.
  """

  use Steward.DataCase, async: true

  alias Steward.SagaExecutor
  alias Steward.Sagas
  alias Steward.Test.Examples
  alias Steward.Test.Examples.Invoice

  defp create_invoice! do
    Examples.create_invoice!(Ecto.UUID.generate(), Decimal.new(100),
      context: %{steward: %{borrow_token: make_ref()}}
    )
  end

  # A plan naming an action that doesn't exist passes static validation
  # (there's no capability/transition to check it against) but fails at
  # execution time on every attempt, deterministically — exactly the kind
  # of failure `retry` can't fix and should eventually escalate.
  defp doomed_plan(invoice) do
    [%{id: 1, resource: Invoice, resource_id: invoice.id, action: :nonexistent_action}]
  end

  test "retry re-invokes the saga, incrementing :attempts on each failure" do
    invoice = create_invoice!()
    assert {:error, _reason} = SagaExecutor.execute(doomed_plan(invoice))

    saga = Sagas.list_sagas!() |> List.first()
    assert saga.status == :failed
    assert saga.attempts == 1

    Sagas.retry_saga!(saga)
    reloaded = Sagas.get_saga!(saga.id)
    assert reloaded.status == :failed
    assert reloaded.attempts == 2
  end

  test "escalates to :dead_letter once attempts reach the ceiling, and the trigger stops matching it" do
    invoice = create_invoice!()
    assert {:error, _reason} = SagaExecutor.execute(doomed_plan(invoice))
    saga = Sagas.list_sagas!() |> List.first()

    saga =
      Enum.reduce(2..5, saga, fn _attempt, saga ->
        Sagas.retry_saga!(saga)
        Sagas.get_saga!(saga.id)
      end)

    assert saga.status == :dead_letter
    assert saga.attempts == 5

    assert [] = Sagas.list_sagas!(query: [filter: [status: :failed]])
  end
end
