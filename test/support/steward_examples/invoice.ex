defmodule Steward.Test.Examples.Invoice do
  @moduledoc """
  A minimal, in-memory (`Ash.DataLayer.Ets`) resource exercising the
  `Steward.Resource` DSL end to end (docs/tech_spec.md §6's own example,
  §8 Phase 3): ownership, capabilities (including a linear, freshness-bound
  `:pay`), a state machine, and locking/idempotency declarations.

  Deliberately not backed by Postgres/`Steward.Changes.EnforceFencing` —
  unlike `Steward.Shadows.Invoice` (Phase 2 scaffolding), this resource's
  only job is proving Phase 3's DSL, witness enforcement, and
  `Steward.PlanValidator` work against a real Ash resource.
  """

  use Ash.Resource,
    otp_app: :steward,
    domain: Steward.Test.Examples,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Steward.Resource]

  ets do
    private? true
  end

  steward do
    ownership(:account_id)

    capability(:read, mode: :shared)
    capability(:approve, mode: :exclusive, reversibility: :undoable, undo: :unapprove)

    capability(:pay,
      mode: :exclusive,
      consumption: :linear,
      reversibility: :compensatable,
      compensate: :refund,
      requires_freshness: {:max_age, 30_000}
    )

    capability(:notify, mode: :shared, reversibility: :irreversible)

    state_machine do
      state(:draft, initial?: true)
      state :approved
      state :paid

      transition :approve, from: :draft, to: :approved
      transition :pay, from: :approved, to: :paid
    end

    locking(:conditional_write)
    idempotency(:header, key: "Idempotency-Key")
  end

  actions do
    defaults [:read]

    create :create do
      accept [:account_id, :total_amount]
    end

    update :approve do
      accept []
      change set_attribute(:status, :approved)
    end

    update :unapprove do
      accept []
      change set_attribute(:status, :draft)
    end

    update :pay do
      argument :amount_paid, :decimal, allow_nil?: false

      change set_attribute(:status, :paid)
      change set_attribute(:amount_paid, arg(:amount_paid))
    end

    update :refund do
      accept []
      change set_attribute(:status, :approved)
      change set_attribute(:amount_paid, Decimal.new(0))
    end

    action :notify, :atom do
      description "Stands in for spec §4.4's `:irreversible` example (\"a sent email\")."
      run fn _input, _context -> {:ok, :sent} end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :account_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:draft, :approved, :paid]
      default :draft
      public? true
    end

    attribute :total_amount, :decimal do
      public? true
    end

    attribute :amount_paid, :decimal do
      default Decimal.new(0)
      public? true
    end
  end
end
