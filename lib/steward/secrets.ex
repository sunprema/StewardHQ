defmodule Steward.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Steward.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:steward, :token_signing_secret)
  end
end
