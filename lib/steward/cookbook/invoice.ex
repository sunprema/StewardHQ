defmodule Steward.Cookbook.Invoice do
  @moduledoc """
  `docs/cookbook.md` Recipe 1's resource: an invoice, governed end to end
  by every phase's machinery at once — the `Steward.Resource` DSL
  (capabilities, state machine, unbypassable witness enforcement),
  `Steward.Changes.EnforceFencing` fencing real writes against
  `Steward.Cookbook.PaymentGateway`, and `Steward.SagaExecutor` running
  a call as a saga (directly, or via `Steward.MCP.Facade`'s
  `pay_invoice`/`approve_invoice`/`read_invoice` tools in dev).

  Dev-only scaffolding — never registered in `config/test.exs` or
  `config/prod.exs` (see `Steward.Cookbook.PaymentGateway`'s moduledoc).
  Private, in-memory ETS storage: nothing here survives a restart, on
  purpose — this is a cookbook, not a real ledger.
  """

  use Ash.Resource,
    otp_app: :steward,
    domain: Steward.Cookbook,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Steward.Resource]

  ets do
    # Deliberately not `private? true`: a private ETS table's reference
    # lives in the *creating process's* dictionary (verified against
    # Ash's own data layer source), so it's invisible to any other
    # process — fine for a single-process test, but wrong for a
    # cookbook whose entire point is showing real requests from
    # different processes (concurrent MCP calls, separate IEx sessions)
    # sharing the same governed resource.
    private? false
  end

  steward do
    ownership(:account_id)

    capability(:read, mode: :shared)

    capability(:approve,
      mode: :exclusive,
      reversibility: :undoable,
      undo: :unapprove
    )

    capability(:pay,
      mode: :exclusive,
      consumption: :linear,
      reversibility: :compensatable,
      compensate: :refund,
      requires_freshness: {:max_age, 30_000}
    )

    state_machine do
      state(:draft, initial?: true)
      state :approved
      state :paid

      transition :approve, from: :draft, to: :approved
      transition :pay, from: :approved, to: :paid
    end

    locking(:conditional_write)
  end

  actions do
    defaults [:read]

    create :create do
      accept [:external_id, :account_id, :total_amount]
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
      require_atomic? false

      argument :amount_paid, :decimal, allow_nil?: false

      change set_attribute(:status, :paid)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :amount_paid,
          Ash.Changeset.get_argument(changeset, :amount_paid)
        )
      end

      change {Steward.Changes.EnforceFencing, backend: Steward.Cookbook.PaymentGateway}
    end

    update :refund do
      require_atomic? false
      accept []
      change set_attribute(:status, :approved)
      change set_attribute(:amount_paid, Decimal.new(0))
      change {Steward.Changes.EnforceFencing, backend: Steward.Cookbook.PaymentGateway}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :external_id, :string do
      allow_nil? false
      public? true
    end

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

    attribute :version, :integer do
      default 0
      public? true
    end

    attribute :sync_status, :atom do
      constraints one_of: [:synced, :stale, :conflicted]
      default :synced
      public? true
    end

    attribute :synced_at, :utc_datetime_usec do
      public? true
    end
  end
end
