import Config

# Integration tests run against a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_billing_test
config :phoenix_kit_billing, ecto_repos: [PhoenixKitBilling.Test.Repo]

config :phoenix_kit_billing, PhoenixKitBilling.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  # Name overridable so a host that cannot create databases (our CI user has
  # no CREATEDB) can point the suite at an existing test database instead of
  # silently losing the whole integration half. Same shape as
  # phoenix_kit_document_creator.
  database:
    System.get_env(
      "PGDATABASE",
      "phoenix_kit_billing_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire repo for PhoenixKit.RepoHelper — without this, context-layer DB calls crash.
config :phoenix_kit, repo: PhoenixKitBilling.Test.Repo

# Test Endpoint for LiveView tests. `phoenix_kit_billing` has no endpoint
# of its own in production — the host app provides one — so this
# endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_billing, PhoenixKitBilling.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "billing-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitBilling.Test.Layouts]]

config :phoenix, :json_library, Jason

config :logger, level: :warning
