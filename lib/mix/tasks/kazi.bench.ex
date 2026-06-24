defmodule Mix.Tasks.Kazi.Bench do
  @shortdoc "Multi-arm token benchmark harness (run by a maintainer with `claude` on PATH)"

  @moduledoc """
  The multi-iteration token-benchmark harness (T19.4, ADR-0010 §"Cache + measure").

      mix kazi.bench --goal <goal-file> --workspace <path> [options]

  Converges a fixture that needs **>= 3 dispatches** three ways and emits a
  per-arm token + cost + iteration table, to answer the question ADR-0010
  promised but the single-dispatch measurement (devlog 2026-06-24 "token
  benchmark (T15.9)") could not: across iterations, does kazi's T19.1 orientation
  prefix + stable head (T19.2) pay for itself?

  ## The three arms

    * **A — vanilla** `claude -p` (no kazi): one freeform `claude -p
      --output-format json` session over the fixture. The amortized baseline.
    * **B — kazi WITHOUT the prefix** (`orientation_prefix: false`, the pre-T19.1
      behaviour): `mix kazi.run` drives `claude`, but the dispatch prompt is the
      evidence-only body — no orientation pack prefix.
    * **C — kazi WITH the prefix** (`orientation_prefix: true`, the current
      default; T19.1 stable head + T19.2 stable-prefix discipline): `mix kazi.run`
      drives `claude` with the ranked orientation pack as a cacheable prefix.

  Arm B vs arm C isolates the prefix's cost; both vs arm A isolate kazi's
  per-iteration re-orientation overhead (the "N× baseline" worst case ADR-0010
  flags). The no-prefix flag (arm B) is the additive `:orientation_prefix`
  adapter opt added to `Kazi.Loop` in T19.4 — default `true`, so arm C is the
  unchanged default and only arm B flips it off.

  ## How tokens are captured

  Mirrors the devlog 2026-06-24 method: each `claude` invocation runs with
  `--output-format json`, whose envelope carries a `usage` object
  (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`) and a top-level `total_cost_usd`. For arm A the
  envelope is the session's own stdout; for arms B/C a thin wrapper on `PATH`
  tees each per-dispatch `claude --output-format json` envelope to a capture
  directory (kazi captures tokens internally but persists none today). Every
  captured envelope is parsed by the PURE `Kazi.Bench.parse_capture/1`, and the
  per-arm rows are aggregated by `Kazi.Bench.report/1` and rendered by
  `Kazi.Bench.render_table/1` — all hermetic and unit-tested.

  ## RUN BY A MAINTAINER (the live run is T19.5)

  **This task delivers the HARNESS; the live 3-arm RUN is T19.5 (operator).** A
  real run needs `claude` on `PATH`, a live model, and the fixture's workspace
  permissions granted — it is NOT exercised by CI or by `mix test` (the
  token-parse + report aggregation are unit-tested against recorded envelopes
  only, with no `claude`/network). A maintainer runs:

      mix kazi.bench --goal priv/examples/<fixture>.toml --workspace <repo> --arms A,B,C

  ## Options

    * `--goal <file>`      — the goal/fixture file the arms converge (REQUIRED to
      run live).
    * `--workspace <path>` — the target workspace for arms B/C (and arm A's `cwd`).
    * `--arms <list>`      — comma-separated subset of `A,B,C` to run (default
      `A,B,C`).
    * `--captures <dir>`   — directory of recorded `claude --output-format json`
      envelopes to aggregate INSTEAD of running live (offline replay; the path
      the hermetic acceptance exercises). One `<arm>.NNN.json` file per dispatch.
    * `--help`             — print this usage (the 3 arms + how to run) and exit.
  """

  use Mix.Task

  alias Kazi.Bench

  @arms ["A", "B", "C"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        switches: [
          goal: :string,
          workspace: :string,
          arms: :string,
          captures: :string,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(usage())

      opts[:captures] ->
        replay_from_captures(opts[:captures], arms(opts))

      true ->
        # No `--captures` and no `--help`: this is the LIVE path, which needs
        # `claude` on PATH and is run by a maintainer (T19.5), not CI. Refuse to
        # pretend — print usage and point at the offline replay / T19.5.
        Mix.shell().info(live_run_notice())
        Mix.shell().info(usage())
    end
  end

  # Offline replay: aggregate recorded `claude --output-format json` envelopes
  # from `<dir>/<arm>.*.json` (per-dispatch) into the per-arm report table. This
  # is the deterministic path the hermetic harness exercises — no `claude`, no
  # network — and the same aggregation a live run feeds its captured envelopes
  # through.
  defp replay_from_captures(dir, arms) do
    report =
      Enum.map(arms, fn arm ->
        {arm, captures_for_arm(dir, arm)}
      end)

    table = report |> Bench.report() |> Bench.render_table()
    Mix.shell().info("kazi.bench — per-arm token + cost + iteration table\n")
    Mix.shell().info(table)
  end

  # Read every `<arm>.*.json` envelope in `dir` (sorted, so dispatch order is
  # stable) and parse each into a per-dispatch capture.
  defp captures_for_arm(dir, arm) do
    dir
    |> Path.join("#{arm}.*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path -> path |> File.read!() |> Bench.parse_capture() end)
  end

  defp arms(opts) do
    case opts[:arms] do
      nil ->
        @arms

      list ->
        list
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.upcase/1)
        |> Enum.filter(&(&1 in @arms))
    end
  end

  defp live_run_notice do
    """
    kazi.bench: no --captures given — the LIVE 3-arm run needs `claude` on PATH
    and is run by a maintainer (T19.5), not by this harness invocation. To
    aggregate recorded envelopes offline, pass --captures <dir>. Usage follows.
    """
  end

  defp usage do
    """
    mix kazi.bench — multi-arm token-benchmark harness (T19.4, ADR-0010)

    Converges a >=3-dispatch fixture three ways and tables per-arm tokens + cost:

      A — vanilla `claude -p` (no kazi): one freeform session.
      B — kazi WITHOUT the orientation prefix (orientation_prefix: false; pre-T19.1).
      C — kazi WITH the orientation prefix (orientation_prefix: true; current default).

    Tokens are captured from each `claude --output-format json` envelope's
    `usage` (input / output / cache_creation / cache_read) + `total_cost_usd`,
    parsed by the pure Kazi.Bench.parse_capture/1 and aggregated by
    Kazi.Bench.report/1 → render_table/1.

    THE LIVE RUN IS T19.5 (maintainer): a real run needs `claude` on PATH and is
    NOT exercised by CI. A maintainer runs:

      mix kazi.bench --goal priv/examples/<fixture>.toml --workspace <repo> --arms A,B,C

    Options:
      --goal <file>       goal/fixture file the arms converge (required to run live)
      --workspace <path>  target workspace for arms B/C (and arm A's cwd)
      --arms <list>       subset of A,B,C to run (default A,B,C)
      --captures <dir>    aggregate recorded envelopes offline instead of running live
      --help, -h          print this usage and exit
    """
  end
end
