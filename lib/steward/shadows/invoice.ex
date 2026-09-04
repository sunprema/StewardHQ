defmodule Steward.Shadows.Invoice do
  @moduledoc """
  Hand-built shadow resource used to exercise `Steward.Changes.EnforceFencing`
  (docs/tech_spec.md §5, §8 Phase 2). This is scaffolding, not a shipped
  feature: it is a stand-in for what the Phase 3 `Steward.Resource` DSL
  will eventually generate from a `Steward.DSL` declaration (spec §6's
  `resource :invoice` example) — hence the deliberately narrow, hardcoded
  shape (fixed backend, no state machine, no capabilities).

  Carries the shadow-state fields CLAUDE.md's conventions require of any
  cache: `version` (the backend's ETag) and `sync_status` (`:synced |
  :stale | :conflicted`), plus `synced_at` to compute staleness age when
  needed.
  """

  use Ash.Resource,
    otp_app: :steward,
    domain: Steward.Shadows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "shadow_invoices"
    repo Steward.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:external_id, :status, :total_amount]
    end

    update :record_payment do
      require_atomic? false

      argument :amount_paid, :decimal, allow_nil?: false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :amount_paid,
          Ash.Changeset.get_argument(changeset, :amount_paid)
        )
      end

      change {Steward.Changes.EnforceFencing, backend: Steward.Test.FakeBackend}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :external_id, :string do
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

  identities do
    identity :unique_external_id, [:external_id]
  end
end
