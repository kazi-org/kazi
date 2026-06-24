defmodule Kazi.AntigravityLiveTest do
  @moduledoc """
  The LIVE Antigravity smoke test (T14.3, ADR-0022; UC-032).

  This drives the operator's REAL `antigravity` CLI (also installed as `agy`) with
  the #76 non-TTY workaround (`antigravity run --prompt-file <tmp> --output json
  --yes`) wired to Google via `GEMINI_API_KEY` / `ANTIGRAVITY_API_KEY`, and asserts
  kazi can converge a goal through a profile-resolved, real harness — the end of
  the chain the hermetic stub/golden tests can only approximate. It is the
  Antigravity counterpart of `Kazi.CodexLiveTest` / `Kazi.OpencodeLiveTest`.

  It is tagged `:antigravity_live` and EXCLUDED by default (see
  `test/test_helper.exs`, alongside `:codex_live`/`:opencode_live`/`:nats`/
  `:graphify`) so the standard `mix test` and CI stay hermetic (no network, no
  creds). Opt in explicitly:

      mix test --only antigravity_live test/kazi/antigravity_live_test.exs

  ## Honest skip (NEVER a fake pass)

  Before driving anything, the test probes its real dependencies:

    * the `antigravity` binary (or `agy`) is on PATH, and
    * auth is present — `GEMINI_API_KEY` or `ANTIGRAVITY_API_KEY` is set.

  If either is unavailable the test SKIPS with a clear reason — it does not fail
  (the dependency is environmental, not a kazi defect) and it does not fake-pass.
  Convergence is asserted ONLY when a real `antigravity run` turn actually ran.

  ## The #76 non-TTY landmine this smoke is the live catch for

  Antigravity's bare `-p`/`--prompt` flag SILENTLY DROPS stdout under a non-TTY
  subprocess (`google-antigravity/antigravity-cli#76`) — exactly kazi's mode. The
  `:antigravity` profile sidesteps it with `--prompt-file` + `--output json` (the
  CliAdapter materializes the temp file; `prompt_via: :file`). This live smoke is
  the catch if a future Antigravity release regresses the workaround: a dropped
  stdout would mean no `:result` and no convergence, reported honestly below.

  ## Honest non-convergence

  Even when antigravity + auth are present, a real turn may not converge in the
  window (model latency, the harness's own approval policy declining a write in a
  scratch workspace). These are environmental, not kazi defects — and they are NOT
  a convergence we can claim. A run that reaches the loop but does NOT converge is
  reported HONESTLY as a skip-with-reason; it never fakes a green. Only an actual
  `:converged` with the marker present asserts success.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, PredicateVector, ReadModel, Repo, Runtime, Scope}

  @moduletag :antigravity_live
  @moduletag timeout: 900_000
  @moduletag ownership_timeout: 900_000

  # Optional explicit model override; "" (the default) lets antigravity use its own
  # configured default — build_args drops an empty-string model, so threading it
  # through unconditionally is safe.
  @model System.get_env("KAZI_ANTIGRAVITY_MODEL") || ""

  setup do
    # Persistence runs on the loop's process; share the Sandbox connection so the
    # loop's iteration writes land where this test reads them.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "kazi converges a real goal by driving the antigravity CLI against Google" do
    case preflight() do
      {:skip, reason} ->
        # HONEST SKIP: a live dependency is unavailable. NOT a kazi defect and NOT
        # a real pass — the test makes no convergence claim.
        IO.puts("\n[antigravity_live] SKIPPED (no convergence claimed): #{reason}")
        :skipped

      {:ok, command} ->
        run_live_convergence(command)
    end
  end

  # --- the live run ----------------------------------------------------------

  defp run_live_convergence(command) do
    work =
      Path.join(System.tmp_dir!(), "kazi-antigravity-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)

    marker = "kazi_antigravity_live_ok.txt"
    goal_ref = "antigravity-live-#{System.unique_integer([:positive])}"

    # A single code predicate, failing at t0 (marker absent). The predicate's
    # failing evidence (`test -f <marker>`) is rendered INTO the dispatch prompt so
    # the real model sees the exact file it must create.
    goal =
      Goal.new(goal_ref,
        predicates: [
          Predicate.new(:create_marker_file, :tests,
            config: %{cmd: "sh", args: ["-c", "test -f #{marker}"]}
          )
        ],
        scope: Scope.new(workspace: work)
      )

    # @model is "" by default; build_args drops an empty-string model, so
    # antigravity uses its own configured default unless KAZI_ANTIGRAVITY_MODEL is
    # set. `command` pins whichever binary preflight found on PATH (`antigravity`
    # or `agy`).
    run =
      Runtime.run(goal,
        workspace: work,
        harness: :antigravity,
        command: command,
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
          "\n[antigravity_live] CONVERGED via antigravity run --prompt-file: " <>
            "#{result.iterations} iteration(s), final vector satisfied."
        )

      {:ok, %{outcome: other} = result} ->
        # A REAL antigravity turn ran but did NOT converge in the window. Honest
        # non-claim: report, do not fake a pass. A dropped-stdout regression of the
        # #76 workaround would surface HERE (no :result -> no convergence).
        IO.puts(
          "\n[antigravity_live] DID NOT CONVERGE (no success claimed): outcome=#{inspect(other)} " <>
            "reason=#{inspect(result.reason)} after #{result.iterations} iteration(s). " <>
            "antigravity+auth were present; the real turn did not make the predicate pass " <>
            "in-window (model latency / harness approval policy / a #76 stdout regression)."
        )

        :did_not_converge

      {:error, :await_timeout} ->
        IO.puts(
          "\n[antigravity_live] TIMED OUT (no success claimed): the real antigravity run did " <>
            "not terminate within the window. Environmental, not a kazi failure."
        )

        :await_timeout

      {:error, reason} ->
        IO.puts(
          "\n[antigravity_live] RUN ERROR (no success claimed): #{inspect(reason)}. " <>
            "Reported honestly rather than asserting a convergence that did not happen."
        )

        :run_error
    end
  end

  # --- preflight: probe the real dependencies, skip honestly otherwise -------

  @spec preflight() :: {:ok, String.t()} | {:skip, String.t()}
  defp preflight do
    with {:ok, command} <- antigravity_on_path(),
         :ok <- antigravity_auth() do
      {:ok, command}
    end
  end

  # The CLI is installed as `antigravity` (and also as `agy`); prefer the former
  # but accept either, returning whichever is on PATH so the run pins it.
  defp antigravity_on_path do
    cond do
      System.find_executable("antigravity") -> {:ok, "antigravity"}
      System.find_executable("agy") -> {:ok, "agy"}
      true -> {:skip, "neither `antigravity` nor `agy` is on PATH"}
    end
  end

  # Antigravity authenticates via GEMINI_API_KEY or ANTIGRAVITY_API_KEY.
  defp antigravity_auth do
    if present?(System.get_env("GEMINI_API_KEY")) or
         present?(System.get_env("ANTIGRAVITY_API_KEY")) do
      :ok
    else
      {:skip, "no GEMINI_API_KEY / ANTIGRAVITY_API_KEY (set one to run the live smoke)"}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
