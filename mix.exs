defmodule PhoenixKitBilling.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_billing"

  def project do
    [
      app: :phoenix_kit_billing,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # `compat/billing.ex` intentionally redefines the core
      # `PhoenixKit.Modules.Billing` namespace during the transition to the
      # `PhoenixKitBilling` namespace, which triggers a module-redefinition
      # warning that `--warnings-as-errors` would otherwise fail on.
      # Removal condition: drop this once core no longer ships the old
      # `PhoenixKit.Modules.Billing` namespace (then delete compat/billing.ex too).
      elixirc_options: [ignore_module_conflict: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_ignore_filters: [~r"/support/"],
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitBilling\.Test\./,
          PhoenixKitBilling.DataCase,
          PhoenixKitBilling.LiveCase,
          PhoenixKitBilling.ActivityLogAssertions
        ]
      ],

      # Hex
      description: "Billing module for PhoenixKit — payments, subscriptions, invoices",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit, :mix]],

      # Docs
      name: "PhoenixKitBilling",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :gettext]]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, "test.reset": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitBilling.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitBilling.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      pk_dep(:phoenix_kit, "~> 1.7"),

      # Gettext for per-module i18n of sidebar tab labels.
      {:gettext, "~> 1.0"},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.1"},

      # Phoenix web framework (controllers, routing).
      {:phoenix, "~> 1.7"},

      # Ecto for database queries and schemas.
      {:ecto_sql, "~> 3.12"},

      # Background job processing (subscription renewals, dunning).
      {:oban, "~> 2.20"},

      # UUIDv7 primary key generation.
      {:uuidv7, "~> 1.0"},

      # Stripe payment provider.
      {:stripity_stripe, "~> 3.2"},

      # HTTP client for PayPal/Razorpay APIs.
      {:req, "~> 0.5"},

      # JSON encoding/decoding.
      {:jason, "~> 1.4"},

      # Documentation generation.
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},

      # Code quality.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # `Phoenix.LiveViewTest` parses HTML via `lazy_html` for `element/2`,
      # `render(view) =~ "..."`, etc. Test-only.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitBilling",
      source_ref: "#{@version}",
      source_url: @source_url
    ]
  end
end
