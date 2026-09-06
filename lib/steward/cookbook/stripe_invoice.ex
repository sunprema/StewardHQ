defmodule Steward.Cookbook.StripeInvoice do
  @moduledoc """
  `docs/cookbook.md` Recipe 3's resource: the same shape as
  `Steward.Cookbook.Invoice`, but fenced against
  `Steward.Cookbook.StripeGateway` instead of the in-memory
  `Steward.Cookbook.PaymentGateway` — a real HTTP round trip to
  `stripe-mock` on every `:pay`/`:refund`, not just an ETS lookup.

  Kept as its own resource rather than making `Invoice`'s backend
  configurable: the two demonstrate genuinely different things (clean,
  fully-controllable conditional-write semantics vs. a real HTTP
  protocol round trip with its own honest limitations — see
  `Steward.Cookbook.StripeGateway`'s moduledoc), and a cookbook reader
  is better served by two small, self-contained resources than one
  parameterized over which lesson it's teaching.

  Dev-only, same as every other `Steward.Cookbook` module.
  """

  use Ash.Resource,
    otp_app: :steward,
    domain: Steward.Cookbook,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Steward.Resource]

  ets do
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

      change {Steward.Changes.EnforceFencing, backend: Steward.Cookbook.StripeGateway}
    end

    update :refund do
      require_atomic? false
      accept []
      change set_attribute(:status, :approved)
      change set_attribute(:amount_paid, Decimal.new(0))
      change {Steward.Changes.EnforceFencing, backend: Steward.Cookbook.StripeGateway}
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
