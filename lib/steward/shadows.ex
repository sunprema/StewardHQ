defmodule Steward.Shadows do
  @moduledoc """
  Domain for hand-built shadow resources (docs/tech_spec.md §5 "Shadow
  resources"). Phase 2 scaffolding only — the Phase 3 `Steward.Resource`
  DSL is what will eventually compile shadow resources like
  `Steward.Shadows.Invoice` from a `Steward.DSL` declaration instead of
  by hand.
  """

  use Ash.Domain,
    otp_app: :steward

  resources do
    resource Steward.Shadows.Invoice do
      define :create_invoice, action: :create
      define :record_payment, action: :record_payment, args: [:amount_paid]
      define :get_invoice, action: :read, get_by: [:id]
    end
  end
end
