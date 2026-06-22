defmodule Kazi.MixProject do
  use Mix.Project

  def project do
    [
      app: :kazi,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      escript: escript(),
      deps: deps()
    ]
  end

  # `mix escript.build` produces the operator-facing `kazi` binary (T0.10). Its
  # entry is Kazi.CLI.main/1 (`kazi run <goal-file> --workspace <path>`).
  defp escript do
    [main_module: Kazi.CLI, name: "kazi"]
  end

  # Compile hermetic test doubles under test/support/ only in the test env (e.g.
  # Kazi.Context.StaticGraphSource — the injectable graph-source seam stub kept
  # out of lib/ by the zero-stub policy).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Kazi.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:toml, "~> 0.7"},
      # Slice-3 operator dashboard (ADR-0011, T3.6). A thin, read-mostly LiveView
      # projection over the read-model + NATS state; it NEVER couples into
      # Kazi.Loop / Kazi.Harness. Cowboy (plug_cowboy) is the HTTP server per the
      # task; phoenix_live_view pulls in phoenix_template + phoenix_pubsub.
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:plug_cowboy, "~> 2.8"},
      # LiveView's connected-mount test helpers (`live/2`) parse the rendered DOM
      # with lazy_html; test-only.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  # Run "mix help do" / "mix help aliases" for more.
  defp aliases do
    [
      # Set up the local read-model: create the SQLite DB and run migrations.
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # Self-contained `mix test`: create + migrate the SQLite read-model before
      # the test run so CI needs no separate DB step (T0.9). `ecto.create`/
      # `ecto.migrate` run against a normal pool and finish before the app boots
      # its Sandbox-pooled repo.
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
