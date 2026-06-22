defmodule Kazi.MixProject do
  use Mix.Project

  def project do
    [
      app: :kazi,
      version: "0.1.0",
      elixir: "~> 1.20",
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
      {:toml, "~> 0.7"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
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
