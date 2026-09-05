defmodule Steward.Test.Examples do
  @moduledoc """
  Test-only Ash domain for `Steward.Test.Examples.Invoice`, the resource
  used to exercise the Phase 3 `Steward.Resource` DSL end to end.
  """

  use Ash.Domain,
    otp_app: :steward

  resources do
    resource Steward.Test.Examples.Invoice do
      define :create_invoice, action: :create, args: [:account_id, :total_amount]
      define :approve_invoice, action: :approve
      define :pay_invoice, action: :pay, args: [:amount_paid]
      define :get_invoice, action: :read, get_by: [:id]
    end
  end
end
