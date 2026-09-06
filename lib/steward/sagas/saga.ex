defmodule Steward.Sagas.Saga do
  @moduledoc """
  Durable saga state (docs/tech_spec.md §4.3 "Compensations fail too. A
  persistent retry queue with dead-letter escalation to humans is
  required — which implies durable saga state (Ash persistence), not
  just in-memory GenServers"; §8 Phase 4).

  One row per `Steward.SagaExecutor` run. `:plan` is the
  `Steward.Sagas.PlanCodec`-encoded step list — kept for audit (a human
  reviewing a `:dead_letter` saga can see exactly what was attempted) and
  for the `:retry` action to resume execution after a crash or transient
  failure, since the in-memory plan doesn't survive process death.

  The "persistent retry queue" is `AshOban`'s trigger machinery
  (already wired into `Steward.Application`): Oban's job table is
  itself the durable queue, so this resource doesn't reimplement one —
  it only records outcomes and exposes a `:retry` action for the
  trigger's worker to call. Escalation to `:dead_letter` ("dead-letter
  escalation to humans") is decided by `Steward.SagaExecutor.resume/1`
  once `:attempts` reaches the retry ceiling, not by Oban's own
  job-retry mechanism — a saga step failing is an expected, structured
  outcome (spec §4.4), not an exception for Oban to catch.

  `:retry` marks the row `:running` and commits; the actual re-execution
  happens after that commit, in `Steward.Sagas.Saga.Changes.Resume` —
  see that module for why a saga must never run inside the transaction
  that schedules it.
  """

  use Ash.Resource,
    otp_app: :steward,
    domain: Steward.Sagas,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban]

  postgres do
    table "sagas"
    repo Steward.Repo
  end

  oban do
    triggers do
      trigger :retry do
        action :retry
        where expr(status == :failed)
        worker_module_name Steward.Sagas.Saga.Workers.Retry
        scheduler_module_name Steward.Sagas.Saga.Schedulers.Retry
        scheduler_cron "* * * * *"
        max_attempts 1
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [:plan]
      change set_attribute(:status, :running)
    end

    update :complete do
      accept []
      require_atomic? false

      change set_attribute(:status, :completed)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :finished_at, DateTime.utc_now())
      end
    end

    update :fail do
      require_atomic? false

      argument :error, :map, allow_nil?: false

      change set_attribute(:status, :failed)
      change set_attribute(:error, arg(:error))

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :finished_at, DateTime.utc_now())
      end

      change atomic_update(:attempts, expr(attempts + 1))
    end

    update :escalate do
      require_atomic? false

      argument :error, :map, allow_nil?: false

      change set_attribute(:status, :dead_letter)
      change set_attribute(:error, arg(:error))

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :finished_at, DateTime.utc_now())
      end

      change atomic_update(:attempts, expr(attempts + 1))
    end

    update :retry do
      accept []
      require_atomic? false

      change set_attribute(:status, :running)
      change set_attribute(:error, nil)
      change set_attribute(:finished_at, nil)
      change Steward.Sagas.Saga.Changes.Resume
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :plan, {:array, :map} do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:running, :completed, :failed, :dead_letter]
      default :running
      public? true
    end

    attribute :error, :map, public?: true
    attribute :attempts, :integer, default: 0, public?: true
    attribute :finished_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    # The inverse of `Steward.Sagas.SagaStep.saga`. The console loads a
    # saga's steps in one query rather than fanning out per row.
    has_many :steps, Steward.Sagas.SagaStep do
      destination_attribute :saga_id
      public? true
    end
  end
end
