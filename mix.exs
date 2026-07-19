defmodule Kazi.MixProject do
  use Mix.Project

  def project do
    [
      app: :kazi,

      # x-release-please-start-version

      version: "1.267.0",

      # x-release-please-end-version
      elixir: "~> 1.20",
      name: "kazi",
      description:
        "An outer-loop reconciliation controller for software goals: declare a goal " <>
          "as machine-checkable predicates and kazi drives a coding agent in a loop " <>
          "until they are objectively true, stuck, or over budget.",
      source_url: "https://github.com/kazi-org/kazi",
      homepage_url: "https://github.com/kazi-org/kazi",
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      escript: escript(),
      releases: releases(),
      deps: deps()
    ]
  end

  # Open-source package metadata (Apache-2.0; see LICENSE + NOTICE).
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/kazi-org/kazi"},
      files: ~w(lib priv mix.exs README.md LICENSE NOTICE)
    ]
  end

  # `MIX_ENV=prod mix release` builds the self-contained `kazi` release under
  # `_build/prod/rel/kazi` (T6.1, ADR-0014). Unlike the escript, a release bundles
  # ERTS *and* compiled NIFs — so the released binary has the full SQLite
  # read-model (the escript silently degrades because it can't carry the exqlite
  # NIF).
  #
  # Burrito (T6.2, ADR-0014) wraps this release into a single self-contained
  # per-platform binary: `steps: [:assemble, &Burrito.wrap/1]` runs the wrapper
  # after the normal assemble step, and the `burrito:` block declares the four
  # targets (macOS aarch64/x86_64 + Linux aarch64/x86_64). Building a cross-target
  # needs Zig + xz; only the HOST target needs building in any given environment,
  # the others are declared so CI (T6.3) can fan a build matrix over them.
  #
  # A Burrito binary boots the release rather than taking an `eval` argument, so
  # the operator's argv (`kazi run goal.toml ...`) reaches the CLI through
  # `Burrito.Util.Args.argv()`; `Kazi.Application.start/2` detects the Burrito run
  # and hands it to `Kazi.Release.burrito_main/0`. The release also keeps the
  # `eval` entry working for a plain (un-wrapped) `mix release`:
  #
  #     # Burrito binary (single self-contained file):
  #     ./burrito_out/kazi_<target> --help
  #     ./burrito_out/kazi_<target> run goal.toml --workspace .
  #
  #     # Plain `mix release` (no Burrito), via the eval command:
  #     _build/prod/rel/kazi/bin/kazi eval 'Kazi.Release.cli(["--help"])'
  #     _build/prod/rel/kazi/bin/kazi eval \
  #       'Kazi.Release.cli(["run", "goal.toml", "--workspace", "."])'
  #
  # `Kazi.Release.{cli,burrito_main}` and the escript all dispatch to the same
  # `Kazi.CLI` core, so `run`/`propose`/`list-proposed`/`approve`/`reject`/`--help`
  # behave identically across every entry.
  defp releases do
    [
      kazi: [
        include_executables_for: [:unix],
        applications: [kazi: :permanent],
        # issue #1006: a kazi run whose on-disk release payload disappears
        # mid-run (manual cleanup, disk pressure) previously crashed the BEAM
        # on the next LAZY module load ({io_lib_pretty,nofile} -> kernel
        # terminated). `mode: :embedded` loads every module at boot instead of
        # on first use, eliminating that class of crash entirely.
        mode: :embedded,
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
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
      # :xmerl (OTP, no external dep) backs the JUnit-XML evidence parser
      # (Kazi.Evidence.Parser, ADR-0041 / T32.2).
      extra_applications: [:logger, :inets, :ssl, :xmerl],
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
      {:lazy_html, ">= 0.1.0", only: :test},
      # NATS client for the cross-node JetStream-KV lease backend
      # (`Kazi.Coordination.Lease.Nats`, T3.1b, ADR-0004; UC-013). Used only by
      # that backend and its integration-tagged test; the default in-memory
      # backend needs no NATS server, so default `mix test` stays hermetic.
      {:gnat, "~> 1.9"},
      # Burrito wraps the `mix release` into a single self-contained per-platform
      # binary that bundles ERTS + the exqlite NIF, giving the shipped binary the
      # full SQLite read-model the escript can't carry (T6.2, ADR-0014). It runs
      # as a release wrapper step (`steps:` in `releases/0`) and the WRAPPED binary
      # reads its argv at runtime via `Burrito.Util.Args.argv()` — so it must be a
      # normal runtime dependency (its modules ship inside the binary), not
      # `runtime: false`.
      # Pinned to the kazi-org fork until the payload-liveness guard lands
      # upstream (ADR-0066, issue #1018): stock burrito 1.5 deletes older
      # versions' install dirs on every launch with no liveness check, killing
      # still-running kazi processes mid-run during release windows.
      {:burrito, github: "kazi-org/burrito", ref: "65eaf29e76e4f4e1d2dc6e410f8b61aee452f51c"}
    ]
  end

  # Run "mix help do" / "mix help aliases" for more.
  defp aliases do
    [
      # Set up the local read-model (SQLite DB + migrations) and point git at
      # the committed hooks dir (.githooks/ -- notably the pre-push guard that
      # keeps anyone, human or agent, from pushing straight to the
      # auto-releasing main branch; see .githooks/pre-push).
      setup: ["deps.get", "ecto.setup", &setup_git_hooks/1],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # Self-contained `mix test`: create + migrate the SQLite read-model before
      # the test run so CI needs no separate DB step (T0.9). `ecto.create`/
      # `ecto.migrate` run against a normal pool and finish before the app boots
      # its Sandbox-pooled repo.
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  # Point git at the committed hooks dir. Best-effort: a non-git context (a
  # source tarball, a hex build sandbox) or a machine without git skips the
  # wiring without failing `mix setup`.
  defp setup_git_hooks(_args) do
    case System.cmd("git", ["config", "core.hooksPath", ".githooks"], stderr_to_stdout: true) do
      {_, 0} -> Mix.shell().info("git hooks wired: core.hooksPath -> .githooks")
      {out, _} -> Mix.shell().info("skipping git hook wiring (not a git checkout?): #{out}")
    end
  rescue
    ErlangError -> Mix.shell().info("skipping git hook wiring (git not on PATH)")
  end
end
