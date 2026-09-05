defmodule Steward.Cookbook do
  @moduledoc """
  Domain for `docs/cookbook.md`'s dev-only, runnable worked examples —
  `Steward.Cookbook.Invoice` and `Steward.Cookbook.Order`, each fenced
  against a dummy `Steward.Backend` (`Steward.Cookbook.PaymentGateway`,
  `Steward.Cookbook.Warehouse`) standing in for a real external system.

  Only registered in `config/dev.exs`'s `ash_domains` — see
  `Steward.Cookbook.PaymentGateway`'s moduledoc for why this whole
  namespace is dev-only by configuration, not by compilation.
  """

  use Ash.Domain,
    otp_app: :steward

  resources do
    resource Steward.Cookbook.Invoice do
      define :create_invoice, action: :create, args: [:external_id, :account_id, :total_amount]
      define :approve_invoice, action: :approve
      define :pay_invoice, action: :pay, args: [:amount_paid]
      define :get_invoice, action: :read, get_by: [:id]
    end

    resource Steward.Cookbook.Order do
      define :create_order,
        action: :create,
        args: [:external_id, :account_id, :sku, :quantity, :amount_paid]

      define :get_order, action: :read, get_by: [:id]
    end
  end
end
