defmodule Kazi.Providers.TestRunner do
  @moduledoc """
  The `:tests` predicate provider (T0.5) — now a thin **preset** over the unified
  command-runner core (T32.1b, ADR-0040 decision 1): `test_runner` ==
  `custom_script` with `verdict = "exit_zero"` and stderr folded into stdout.

  This is the canonical objective check of Slice 0: a predicate's truth is the
  exit status of a real command run *in the workspace where the agent edits*, not
  an agent's opinion (concept §3, ADR-0002). A command that exits `0` is a
  `:pass`; a non-zero exit is real failing work (`:fail`); an inability to run the
  command at all (binary missing, bad config) is an `:error`, never a `:fail` —
  conflating the two would dispatch a fixer agent against an infra problem
  (`Kazi.PredicateResult`, ADR-0002).

  > #### Deprecated alias {: .warning}
  >
  > The `test_runner` provider name is **deprecated** (ADR-0040 decision 7) and
  > scheduled for removal in **v2.0.0**. It keeps working through the migration
  > window as this preset; new goals should declare `provider = "custom_script"`
  > with `verdict = "exit_zero"`. See `docs/deprecations.md`. The loader emits a
  > one-line migration hint to STDERR when a goal still uses the alias.

  ## Config

  The predicate's `config` map carries the command, run via `System.cmd/3`:

    * `:cmd`  — the executable (string). Required. ONE executable, not a command
      line (`cmd: "go"`, not `cmd: "go test ./..."`); use `:args` for the rest
      (docs/lore.md L-0012).
    * `:args` — argument list (list of strings). Optional, defaults to `[]`.
    * `:env`  — extra environment as `{name, value}` pairs. Optional.

  A shell one-liner is `cmd: "sh", args: ["-c", "mix test"]`.

  ## Context

  `context[:workspace]` is the directory the command runs in (`cd:`), so a
  relative-path test command resolves against the same tree the harness edits
  (`Kazi.HarnessAdapter`). Defaults to the current directory when absent.

  ## Evidence

  Every result carries the proof a fixer agent needs to act (ADR-0002): the
  resolved `:cmd`, `:args`, and `:workspace`; the `:verdict` (`"exit_zero"`); on a
  completed run the `:exit` code and combined stdout+stderr `:output`; on a
  provider error a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CustomScript

  @impl true
  def evaluate(%Predicate{kind: :tests, config: config}, context) do
    # The preset: run the declared command through the one engine with the
    # exit-0-means-pass verdict, folding stderr into stdout so the retained
    # evidence is the combined stream a developer reads.
    config
    |> Map.merge(%{verdict: "exit_zero", merge_stderr: true})
    |> CustomScript.evaluate_config(context)
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end
end
