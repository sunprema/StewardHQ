defmodule Steward.Accounts do
  use Ash.Domain,
    otp_app: :steward

  resources do
    resource Steward.Accounts.Token
    resource Steward.Accounts.User
  end
end
