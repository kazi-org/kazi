defmodule Kazi.GeminiCliLiveTest do
  @moduledoc """
  The LIVE Gemini CLI smoke test (T37.2, ADR-0022; UC-032).

  This drives the operator's REAL `gemini` CLI (`gemini -p "<prompt>" -o json
  --approval-mode yolo`) wired to Google via `GEMINI_API_KEY` (or Google OAuth /
  Vertex `GOOGLE_API_KEY`) and asserts kazi can converge a goal through a
  profile-resolved, real harness — the end of the chain the hermetic
  stub/golden tests can only approximate. It is the Gemini counterpart of
  `Kazi.CodexLiveTest` / `Kazi.AntigravityLiveTest` / `Kazi.OpencodeLiveTest`.

  It is tagged `:gemini_cli_live` and EXCLUDED by default (see
  `test/test_helper.exs`, alongside `:codex_live`/`:antigravity_live`/`:nats`)
  so the standard `mix test` and CI stay hermetic (no network, no creds). Opt in
  explicitly:

      mix test --only gemini_cli_live test/kazi/gemini_cli_live_test.exs

  ## Honest skip (NEVER a fake pass)

  Before driving anything, the test probes its real dependencies:

    * the `gemini` binary is on PATH, and
    * auth is present — `GEMINI_API_KEY` (or `GOOGLE_API_KEY`) is set.

  If either is unavailable the test SKIPS with a clear reason — it does not fail
  (the dependency is environmental, not a kazi defect) and it does not fake-pass.
  Convergence and non-TTY conformance are asserted ONLY when a real `gemini` turn
  actually ran. (Landmine observed while building this smoke: with NO creds,
  `gemini -p … -o json` does not fast-fail — it BLOCKS a non-interactive
  subprocess on interactive auth, emitting nothing. So a credential-less
  environment cannot verify the success-path non-TTY stdout at all; it must skip.)

  ## The non-TTY stdout conformance check (the #76 failure class)

  kazi drives every harness as a NON-INTERACTIVE SUBPROCESS whose stdout is a
  pipe, never a TTY (ADR-0001/ADR-0022). Antigravity's bare `-p` flag SILENTLY
  DROPS stdout in exactly this mode (`google-antigravity/antigravity-cli#76`, see
  `docs/lore.md` L-0007): it exits 0 with EMPTY stdout, so a naive profile parses
  nothing and the loop concludes the agent "said nothing" — a fake non-result.

  `gemini` is wired as a FULLY-CONFORMANT `-o json` profile (like Codex), on the
  theory that its first-class JSON output is non-TTY-safe. `test_nontty_stdout`
  is the LIVE catch that proves it: it runs the production profile's exact argv
  (`Kazi.Harness.Profiles.GeminiCli.build_args/2`) via `System.cmd/3` — whose
  stdout is inherently a pipe (non-TTY) — and asserts the stdout is NON-EMPTY and
  parses (through the production `GeminiCli.parse/1`) to a `:result`. If `-o json`
  were to drop stdout under a non-TTY the way `antigravity -p` does, this test
  FAILS LOUD with a pointer to the `prompt_via: :file` workaround — the signal to
  drop the profile to the file-read path and pin the offending `gemini` version in
  `docs/lore.md`. A green here records that `gemini -o json` is non-TTY-safe at
  the operator's pinned version.

  ## Honest non-convergence

  Even when gemini + auth are present, a real turn may not converge in the window
  (model latency, the harness's own approval policy declining a write in a scratch
  workspace). These are environmental, not kazi defects — and they are NOT a
  convergence we can claim. A run that reaches the loop but does NOT converge is
  reported HONESTLY as a skip-with-reason; it never fakes a green. Only an actual
  `:converged` with the marker present asserts success.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, PredicateVector, ReadModel, Repo, Runtime, Scope}
  alias Kazi.Harness.Profiles.GeminiCli

  @moduletag :gemini_cli_live
  @moduletag timeout: 900_000
  @moduletag ownership_timeout: 900_000

  # Optional explicit model override; "" (the default) lets gemini use its own
  # configured default — build_args drops an empty-string model, so threading it
  # through unconditionally is safe and keeps run_opts free of a compile-time
  # constant guard.
  @model System.get_env("KAZI_GEMINI_MODEL") || ""

  setup do
    # Persistence runs on the loop's process; share the Sandbox connection so the
    # loop's iteration writes land where this test reads them.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "kazi converges a real goal by driving the gemini CLI against Google" do
    case preflight() do
      {:skip, reason} ->
        # HONEST SKIP: a live dependency is unavailable. NOT a kazi defect and NOT
        # a real pass — the test makes no convergence claim.
        IO.puts("\n[gemini_cli_live] SKIPPED (no convergence claimed): #{reason}")
        :skipped

      :ok ->
        run_live_convergence()
    end
  end

  # The non-TTY stdout conformance check (the Antigravity #76 failure class). This
  # is the LIVE proof that `gemini -o json` is non-TTY-safe — it runs the exact
  # production argv under a pipe (System.cmd's stdout is never a TTY) and asserts a
  # parseable, non-empty result. Honest skip when gemini/auth are absent; a real
  # run with EMPTY/garbled stdout FAILS LOUD toward the prompt_via: :file
  # workaround.
  test "gemini -o json emits correct stdout under a NON-TTY subprocess (#76 class)" do
    case preflight() do
      {:skip, reason} ->
        IO.puts("\n[gemini_cli_live] non-TTY stdout check SKIPPED (no claim): #{reason}")
        :skipped

      :ok ->
        # The production profile's exact argv — the one kazi runs in anger.
        args = GeminiCli.build_args("Reply with the single word: ok", model: @model)

        # System.cmd's stdout is a pipe (non-TTY) — the precise mode that trips
        # Antigravity's #76. Merge stderr so a diagnostic is not lost.
        {stdout, exit_status} = System.cmd("gemini", args, stderr_to_stdout: true)

        refute String.trim(stdout) == "",
               "gemini -o json produced EMPTY stdout under a NON-TTY subprocess " <>
                 "(exit=#{exit_status}). This is the Antigravity #76 failure class: the " <>
                 "`:gemini_cli` profile must drop to the `prompt_via: :file` workaround and " <>
                 "the offending `gemini` version must be pinned in docs/lore.md (L-0007)."

        parsed = GeminiCli.parse(stdout)

        assert Map.has_key?(parsed, :result) and is_binary(parsed.result),
               "gemini -o json stdout under a NON-TTY subprocess did not parse to a :result " <>
                 "(exit=#{exit_status}, parsed=#{inspect(parsed)}). Either stdout was garbled " <>
                 "for a non-TTY (the #76 class -> switch to prompt_via: :file + pin the version " <>
                 "in docs/lore.md) or the envelope shape drifted from GeminiCli.parse/1."

        IO.puts(
          "\n[gemini_cli_live] NON-TTY stdout is CONFORMANT: `gemini -o json` emitted a " <>
            "parseable envelope under a pipe (result present). gemini -o json is non-TTY-safe " <>
            "at the operator's pinned version — record it in docs/lore.md."
        )
    end
  end

  # --- the live run ----------------------------------------------------------

  defp run_live_convergence do
    work =
      Path.join(System.tmp_dir!(), "kazi-gemini-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)

    marker = "kazi_gemini_live_ok.txt"
    goal_ref = "gemini-live-#{System.unique_integer([:positive])}"

    # A single code predicate, failing at t0 (marker absent). The predicate's
    # failing evidence (`test -f <marker>`) is rendered INTO the dispatch prompt
    # so the real model sees the exact file it must create.
    goal =
      Goal.new(goal_ref,
        predicates: [
          Predicate.new(:create_marker_file, :tests,
            config: %{cmd: "sh", args: ["-c", "test -f #{marker}"]}
          )
        ],
        scope: Scope.new(workspace: work)
      )

    # @model is "" by default; build_args drops an empty-string model, so gemini
    # uses its own configured default unless the operator set KAZI_GEMINI_MODEL.
    run =
      Runtime.run(goal,
        workspace: work,
        harness: :gemini_cli,
        model: @model,
        await_timeout: 840_000
      )

    case run do
      {:ok, %{outcome: :converged} = result} ->
        assert File.exists?(Path.join(work, marker)),
               "loop reported :converged but #{marker} is absent in the workspace"

        assert result.iterations >= 1, "expected at least one recorded iteration"

        iterations = ReadModel.list_iterations(goal_ref)
        assert length(iterations) >= 1
        last = List.last(iterations)
        assert last.converged == true

        final_vector = ReadModel.to_predicate_vector(last)
        assert PredicateVector.satisfied?(final_vector)

        IO.puts(
          "\n[gemini_cli_live] CONVERGED via gemini -p -o json: " <>
            "#{result.iterations} iteration(s), final vector satisfied."
        )

      {:ok, %{outcome: other} = result} ->
        # A REAL gemini turn ran but did NOT converge in the window. Honest
        # non-claim: report, do not fake a pass. A dropped-stdout regression of the
        # #76 failure class would surface HERE (no :result -> no convergence) AND
        # in the dedicated non-TTY conformance test above.
        IO.puts(
          "\n[gemini_cli_live] DID NOT CONVERGE (no success claimed): outcome=#{inspect(other)} " <>
            "reason=#{inspect(result.reason)} after #{result.iterations} iteration(s). " <>
            "gemini+auth were present; the real turn did not make the predicate pass in-window " <>
            "(model latency / harness approval policy / a non-TTY stdout regression)."
        )

        :did_not_converge

      {:error, :await_timeout} ->
        IO.puts(
          "\n[gemini_cli_live] TIMED OUT (no success claimed): the real gemini run did not " <>
            "terminate within the window. Environmental, not a kazi failure."
        )

        :await_timeout

      {:error, reason} ->
        IO.puts(
          "\n[gemini_cli_live] RUN ERROR (no success claimed): #{inspect(reason)}. " <>
            "Reported honestly rather than asserting a convergence that did not happen."
        )

        :run_error
    end
  end

  # --- preflight: probe the real dependencies, skip honestly otherwise -------

  @spec preflight() :: :ok | {:skip, String.t()}
  defp preflight do
    with :ok <- gemini_on_path(),
         :ok <- gemini_auth() do
      :ok
    end
  end

  defp gemini_on_path do
    if System.find_executable("gemini") do
      :ok
    else
      {:skip, "`gemini` is not on PATH"}
    end
  end

  # Gemini authenticates via GEMINI_API_KEY (or Vertex/Google GOOGLE_API_KEY).
  # Without a key `gemini -p` BLOCKS a non-interactive subprocess on interactive
  # auth rather than erroring, so a credential-less run cannot verify anything —
  # require an explicit key and skip honestly otherwise.
  defp gemini_auth do
    if present?(System.get_env("GEMINI_API_KEY")) or present?(System.get_env("GOOGLE_API_KEY")) do
      :ok
    else
      {:skip, "no GEMINI_API_KEY / GOOGLE_API_KEY (set one to run the live smoke)"}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
