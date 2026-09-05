defmodule Steward.Sagas.SagaStep do
  @moduledoc """
  Durable per-step execution record for a `Steward.Sagas.Saga`
  (docs/tech_spec.md §4.3, §8 Phase 4).

  `Steward.Sagas.StepRunner` writes one of these per plan step as it
  runs — including compensation/undo outcomes — so a saga's audit trail
  survives a crash and a `:dead_letter` saga can be diagnosed by a human
  without needing the original in-memory Reactor run.

  `:disposition` records CLAUDE.md invariant 3's capability disposition
  by error type: `:consumed` (succeeded, `consumption: :linear`),
  `:survived` (failed `:stale_resource`, resynced and retried),
  `:dropped` (failed `:invalid_transition`, forcing a fresh borrow and
  re-observation upstream), or `nil` (not applicable — the step
  succeeded with a `:reusable` capability, or hasn't finished).
  """

  use Ash.Resource,
    otp_app: :steward,
    domain: Steward.Sagas,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "saga_steps"
    repo Steward.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:saga_id, :step_id, :resource, :resource_id, :action]
      upsert? true
      upsert_identity :unique_saga_step
    end

    update :succeed do
      accept []
      argument :result, :map
      argument :disposition, :atom

      change set_attribute(:status, :succeeded)
      change set_attribute(:result, arg(:result))
      change set_attribute(:disposition, arg(:disposition))
    end

    update :fail do
      accept []
      argument :error, :map
      argument :disposition, :atom

      change set_attribute(:status, :failed)
      change set_attribute(:error, arg(:error))
      change set_attribute(:disposition, arg(:disposition))
    end

    update :undo do
      accept []
      change set_attribute(:status, :undone)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :saga_id, :uuid, allow_nil?: false, public?: true
    attribute :step_id, :string, allow_nil?: false, public?: true
    attribute :resource, :string, allow_nil?: false, public?: true
    attribute :resource_id, :string, allow_nil?: false, public?: true
    attribute :action, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      constraints one_of: [:pending, :succeeded, :failed, :undone]
      default :pending
      public? true
    end

    attribute :disposition, :atom do
      constraints one_of: [:consumed, :survived, :dropped]
      public? true
    end

    attribute :result, :map, public?: true
    attribute :error, :map, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :saga, Steward.Sagas.Saga do
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_saga_step, [:saga_id, :step_id]
  end
end
