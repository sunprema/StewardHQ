defmodule Steward.Sagas.Saga.Changes.Resume do
  @moduledoc """
  Re-runs a failed saga's plan, *after* the `:retry` action's transaction
  has committed (docs/tech_spec.md §4.3 "persistent retry queue with
  dead-letter escalation"; §8 Phase 4).

  ## Why `after_transaction` and not `after_action`

  `Steward.SagaExecutor.resume/1` is not a database side effect. It
  acquires plan-scoped borrows, takes leases, calls the legacy backend
  over the network, and then writes the outcome back to *this same saga
  row* via `complete_saga!` / `fail_saga!` / `escalate_saga!`.

  Run from `after_action`, all of that happens inside the transaction the
  `:retry` update opened, which means:

    * the saga row is write-locked for the entire duration of an external
      call — the exact "long transaction across a network boundary"
      shape that turns one slow backend into a stalled queue;
    * the outcome write is a nested update against a row the enclosing
      transaction has not finished with; and
    * a rollback anywhere in the retry would silently undo the outcome
      record for work the backend has already performed — the phantom
      write spec §4.2 exists to prevent, reintroduced on the recovery
      path.

  `after_transaction` runs once the `:retry` update is durably committed,
  so the saga is observably `:running` before any backend call is made,
  and each outcome write is its own short transaction.

  The resume result is deliberately swallowed: a saga failing again is an
  expected, structured outcome (spec §4.4) that `Steward.SagaExecutor`
  has already recorded — including escalation to `:dead_letter` at the
  attempt ceiling. Returning it as an error here would fail the `:retry`
  action itself, which did succeed, and would make AshOban retry the
  *job* on top of the saga's own retry accounting.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, saga} ->
        _ = Steward.SagaExecutor.resume(saga)
        {:ok, saga}

      _changeset, {:error, _reason} = error ->
        error
    end)
  end
end
