defmodule Steward.SagaExecutor do
  @moduledoc """
  Executes a validated plan as a Reactor saga (docs/tech_spec.md §7
  "Execution Flow", §8 Phase 4).

  Mirrors the spec's execution flow directly:

    1. **Static analysis** — `Steward.PlanValidator.validate/2`. A plan
       that fails validation never acquires a single borrow.
    2. **Borrow acquisition** — `Steward.PlanValidator.canonical_borrow_targets/1`
       gives the deadlock-avoiding order; every resource's borrow is
       acquired once, up front, and held for the whole saga (CLAUDE.md:
       "Borrows may be plan-scoped where later steps might trigger an
       earlier step's undo — releasing early would expose intermediate
       state to other agents").
    3. **Durable saga state** — `Steward.Sagas.Saga` is created (or, for
       `resume/1`, already exists) before the Reactor runs, so a crash
       mid-saga leaves a `:running` row an operator (or the `retry`
       AshOban trigger) can find.
    4. **Fenced execution** — a `Reactor.t()` is built dynamically, one
       `Steward.Sagas.StepRunner` step per plan step, chained in the
       plan's given order via a data dependency on the previous step's
       result (Reactor's scheduler is otherwise free to parallelize
       independent steps, which would defeat the ordering `Steward.PlanValidator`
       already checked).
    5. **Completion or unwind** — `Reactor.run/1` handles run/compensate/undo
       itself (spec §4.3); this module just persists the outcome and
       releases the plan-scoped borrows once execution has stopped
       (CLAUDE.md invariant 5: release only after the run — success or
       fully unwound — is settled, never mid-step).

  `resume/1` is the other entry point: the `:retry` action on
  `Steward.Sagas.Saga` (triggered by AshOban's persistent retry queue)
  calls back into this module with the persisted saga, decoded from
  `Steward.Sagas.PlanCodec`, and decides dead-letter escalation once
  `attempts` reaches `@max_attempts` — "dead-letter escalation to
  humans" (spec §4.3) is this decision, not an Oban-level retry
  exhaustion, since a saga step failing is a structured, expected
  outcome (spec §4.4), not an exception.
  """

  alias Steward.{PlanValidator, ResourceServer, Sagas}
  alias Steward.Sagas.{PlanCodec, StepRunner}

  @max_attempts 5

  @doc """
  Validates and executes a brand-new plan, persisting a
  `Steward.Sagas.Saga` row for it. `opts` are forwarded to
  `Steward.PlanValidator.validate/2`.
  """
  @spec execute([PlanValidator.step()], keyword()) :: {:ok, term()} | {:error, term()}
  def execute(steps, opts \\ []) do
    with :ok <- PlanValidator.validate(steps, opts) do
      run_and_persist(steps, fn -> Sagas.create_saga!(PlanCodec.encode(steps)) end)
    end
  end

  @doc """
  Resumes an already-persisted, previously-failed saga (the AshOban
  `retry` trigger's entry point). Re-validates nothing — the plan was
  valid when first submitted, and re-validating against a possibly
  already-mutated resource would just reproduce the same drift the
  original run is trying to recover from.
  """
  @spec resume(Sagas.Saga.t()) :: {:ok, term()} | {:error, term()}
  def resume(%Sagas.Saga{} = saga) do
    steps = PlanCodec.decode(saga.plan)
    run_and_persist(steps, fn -> saga end)
  end

  defp run_and_persist(steps, get_saga) do
    targets = PlanValidator.canonical_borrow_targets(steps)

    case acquire_borrows(targets) do
      {:ok, borrow_tokens} ->
        saga = get_saga.()
        result = run_reactor(steps, saga.id, borrow_tokens)
        release_borrows(borrow_tokens)
        persist_outcome(saga, result)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_outcome(saga, {:ok, _value}), do: Sagas.complete_saga!(saga)

  defp persist_outcome(saga, {:error, reason}) do
    detail = %{"reason" => inspect(reason)}

    if saga.attempts + 1 >= @max_attempts do
      Sagas.escalate_saga!(saga, detail)
    else
      Sagas.fail_saga!(saga, detail)
    end
  end

  defp acquire_borrows(targets) do
    Enum.reduce_while(targets, {:ok, %{}}, fn {key, mode}, {:ok, acquired} ->
      case ResourceServer.acquire(key, mode) do
        {:ok, borrow_ref} ->
          {:cont, {:ok, Map.put(acquired, key, borrow_ref)}}

        {:error, reason} ->
          release_borrows(acquired)
          {:halt, {:error, {:borrow_failed, key, reason}}}
      end
    end)
  end

  defp release_borrows(borrow_tokens) do
    Enum.each(borrow_tokens, fn {key, borrow_ref} -> ResourceServer.release(key, borrow_ref) end)
  end

  defp run_reactor([], _saga_id, _borrow_tokens), do: {:ok, []}

  defp run_reactor(steps, saga_id, borrow_tokens) do
    reactor =
      steps
      |> Enum.with_index()
      |> Enum.reduce(Reactor.Builder.new(), fn {step, index}, reactor ->
        impl =
          {StepRunner, [plan_step: step, saga_id: saga_id, borrow_tokens: borrow_tokens]}

        Reactor.Builder.add_step!(
          reactor,
          step_name(step),
          impl,
          previous_step_argument(steps, index),
          max_retries: StepRunner.max_retries(step),
          async?: false
        )
      end)

    reactor = Reactor.Builder.return!(reactor, step_name(List.last(steps)))
    Reactor.run(reactor)
  end

  defp step_name(step), do: {:step, step.id}

  defp previous_step_argument(_steps, 0), do: []

  defp previous_step_argument(steps, index) do
    [Reactor.Argument.from_result(:previous, step_name(Enum.at(steps, index - 1)))]
  end
end
