defmodule Steward.Cookbook.Order do
  @moduledoc """
  `docs/cookbook.md` Recipe 2's resource: cancelling an order is a
  three-step plan — `:refund` (fenced against `Steward.Cookbook.PaymentGateway`),
  `:restock` (fenced against `Steward.Cookbook.Warehouse`), `:notify`
  (irreversible, no backend at all — a stand-in for a sent email, the
  same pattern `Steward.Test.Examples.Invoice` uses). Run as one plan
  through `Steward.SagaExecutor.execute/2`, a failure partway through
  (see `Steward.Cookbook.Warehouse.simulate_failure/2`) unwinds whatever
  already succeeded — `:refund` gets undone because `:restock` failed —
  instead of leaving the order in a half-cancelled state.

  Dev-only scaffolding, same as `Steward.Cookbook.Invoice` — see
  `Steward.Cookbook.PaymentGateway`'s moduledoc for why.
  """

  use Ash.Resource,
    otp_app: :steward,
    domain: Steward.Cookbook,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Steward.Resource]

  ets do
    # See Steward.Cookbook.Invoice's moduledoc/comment for why this is
    # deliberately not `private? true`.
    private? false
  end

  steward do
    ownership(:account_id)

    capability(:read, mode: :shared)

    capability(:refund,
      mode: :exclusive,
      reversibility: :compensatable,
      compensate: :unrefund
    )

    capability(:restock,
      mode: :exclusive,
      reversibility: :undoable,
      undo: :unrestock
    )

    capability(:notify, mode: :shared, reversibility: :irreversible)

    state_machine do
      state(:placed, initial?: true)
      state :refunded
      state :restocked

      transition :refund, from: :placed, to: :refunded
      transition :restock, from: :refunded, to: :restocked
    end

    locking(:conditional_write)
  end

  actions do
    defaults [:read]

    create :create do
      accept [:external_id, :account_id, :sku, :quantity, :amount_paid]
    end

    update :refund do
      require_atomic? false
      accept []
      change set_attribute(:status, :refunded)
      change {Steward.Changes.EnforceFencing, backend: Steward.Cookbook.PaymentGateway}
    end

    update :unrefund do
      require_atomic? false
      accept []
      change set_attribute(:status, :placed)
      change {Steward.Changes.EnforceFencing, backend: Steward.Cookbook.PaymentGateway}
    end

    update :restock do
      require_atomic? false
      accept []
      change set_attribute(:status, :restocked)
      change {Steward.Changes.EnforceFencing, backend: Steward.Cookbook.Warehouse}
    end

    update :unrestock do
      require_atomic? false
      accept []
      change set_attribute(:status, :refunded)
      change {Steward.Changes.EnforceFencing, backend: Steward.Cookbook.Warehouse}
    end

    action :notify, :atom do
      description "Stands in for spec §4.4's `:irreversible` example (\"a sent email\") — no backend call at all."
      run fn _input, _context -> {:ok, :sent} end
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

    attribute :sku, :string do
      public? true
    end

    attribute :quantity, :integer do
      default 1
      public? true
    end

    attribute :amount_paid, :decimal do
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:placed, :refunded, :restocked]
      default :placed
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
