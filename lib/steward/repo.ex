defmodule Steward.Repo do
  use Ecto.Repo,
    otp_app: :steward,
    adapter: Ecto.Adapters.Postgres
end
