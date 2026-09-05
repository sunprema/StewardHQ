import Config
config :steward, Oban, testing: :manual
config :steward, token_signing_secret: "EjROllqn11W8nh9g+/sl4kLT5Z8YxOby"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Test-only domain exercising the Steward.Resource DSL (Phase 3) end to
# end, on top of the app's real domains.
config :steward,
  ash_domains: [Steward.Accounts, Steward.Shadows, Steward.Sagas, Steward.Test.Examples]

# Exercises Steward.MCP.Facade end to end against the same test resource
# Phase 3/4's own test suites already use.
config :steward, Steward.MCP.Facade,
  resources: [{Steward.Test.Examples.Invoice, state_attribute: :status}]

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :steward, Steward.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "stewardhq_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :steward, StewardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "wXCFMS398g8epCrUVY7tkCfrww5KM9jI1V1ZuV8q8rJWjxJTilKmIToFk7qkSPpd",
  server: false

# In test we don't send emails
config :steward, Steward.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
