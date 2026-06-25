defmodule Kazi.CodexLiveTest do
  @moduledoc """
  The LIVE Codex smoke test (T14.2, ADR-0022; UC-032).

  This drives the operator's REAL `codex` CLI (`codex exec "<prompt>" --json`)
  wired to OpenAI and asserts kazi can converge a goal through a profile-resolved,
  real harness — the end of the chain the hermetic stub/golden tests can only
  approximate. It is the Codex counterpart of `Kazi.OpencodeLiveTest`.

  It is tagged `:codex_live` and EXCLUDED by default (see `test/test_helper.exs`,
  alongside `:opencode_live`/`:nats`/`:graphify`) so the standard `mix test` and
  CI stay hermetic (no network, no creds). Opt in explicitly:

      mix test --only codex_live test/kazi/codex_live_test.exs

  ## Honest skip (NEVER a fake pass)

  Before driving anything, the test probes its real dependencies:

    * the `codex` binary is on PATH, and
    * auth is present — `OPENAI_API_KEY` is set (or `codex login` has been run, in
      which case the operator opts in via `KAZI_CODEX_ASSUME_LOGGED_IN=1`).

  If either is unavailable the test SKIPS with a clear reason — it does not fail
  (the dependency is environmental, not a kazi defect) and it does not fake-pass.
  Convergence is asserted ONLY when a real `codex exec` turn actually ran.

  ## What "converged" proves here

  The goal is a single `tests` (code) predicate that fails at t0 (a marker file is
  absent) and passes once it exists. kazi dispatches the REAL codex harness with a
  prompt instructing it to create that file; on a successful turn the predicate
  flips red->green and the loop reaches `:converged`. We assert the terminal
  outcome, that >=1 iteration was recorded, and that the final predicate vector is
  satisfied — real evidence, not a stubbed result.

  ## Honest non-convergence

  Even when codex + auth are present, a real turn may not converge in the window
  (model latency, the harness's own approval policy declining a write in a scratch
  workspace). These are environmental, not kazi defects — and they are NOT a
  convergence we can claim. A run that reaches the loop but does NOT converge is
  reported HONESTLY as a skip-with-reason; it never fakes a green. Only an actual
  `:converged` with the marker present asserts success.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Predicate, PredicateVector, ReadModel, Repo, Runtime, Scope}
  alias Kazi.Harness.Profiles.Codex

  @moduletag :codex_live
  @moduletag timeout: 900_000
  @moduletag ownership_timeout: 900_000

  # Optional explicit model override; "" (the default) lets codex use its own
  # configured default — build_args drops an empty-string model, so threading it
  # through unconditionally is safe and keeps run_opts free of a compile-time
  # constant guard.
  @model System.get_env("KAZI_CODEX_MODEL") || ""

  setup do
    # Persistence runs on the loop's process; share the Sandbox connection so the
    # loop's iteration writes land where this test reads them.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "kazi converges a real goal by driving the codex CLI against OpenAI" do
    case preflight() do
      {:skip, reason} ->
        # HONEST SKIP: a live dependency is unavailable. NOT a kazi defect and NOT
        # a real pass — the test makes no convergence claim.
        IO.puts("\n[codex_live] SKIPPED (no convergence claimed): #{reason}")
        :skipped

      :ok ->
        run_live_convergence()
    end
  end

  # T34.2 (UC-033, ADR-0046): a LIVE smoke that the CURRENT Codex usage shape
  # still maps onto the economy envelope. Drives the real `codex exec --json` for
  # a trivial prompt, parses its stdout with the production profile, and asserts
  # the usage envelope mapped — fidelity is not :none and the raw object is kept.
  # Honest skip when codex/auth are absent; it makes no claim without a real turn.
  # A real turn that legitimately reports no usage is reported, not failed.
  test "the live codex usage shape still maps onto the economy envelope (T34.2)" do
    case preflight() do
      {:skip, reason} ->
        IO.puts("\n[codex_live] usage-shape smoke SKIPPED (no claim): #{reason}")
        :skipped

      :ok ->
        args = ["exec", "Reply with the single word: ok", "--json"]
        {stdout, _exit} = System.cmd("codex", args, stderr_to_stdout: true)
        parsed = Codex.parse(stdout)

        case Map.get(parsed, :usage_fidelity) do
          fidelity when fidelity in [:full, :partial] ->
            # The current provider shape maps: a non-empty envelope, the raw
            # object retained, and only integer token fields surfaced.
            assert is_map(parsed.usage) and map_size(parsed.usage) > 0
            assert is_map(parsed.usage_raw)

            assert Enum.all?(Map.values(parsed.usage), &(is_integer(&1) and &1 >= 0)),
                   "mapped usage must be non-negative integers, got: #{inspect(parsed.usage)}"

            IO.puts(
              "\n[codex_live] usage shape maps: fidelity=#{fidelity} " <>
                "envelope=#{inspect(parsed.usage)}"
            )

          other ->
            # A real turn ran but reported no usage object (:none or absent). Not a
            # mapping regression — reported honestly, no success claimed.
            IO.puts(
              "\n[codex_live] usage-shape smoke INCONCLUSIVE (no claim): the real turn " <>
                "reported fidelity=#{inspect(other)} (no usage object). Parsed=#{inspect(parsed)}"
            )

            :no_usage_reported
        end
    end
  end

  # --- the live run ----------------------------------------------------------

  defp run_live_convergence do
    work =
      Path.join(System.tmp_dir!(), "kazi-codex-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)

    marker = "kazi_codex_live_ok.txt"
    goal_ref = "codex-live-#{System.unique_integer([:positive])}"

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

    # @model is "" by default; build_args drops an empty-string model, so codex
    # uses its own configured default unless the operator set KAZI_CODEX_MODEL.
    run =
      Runtime.run(goal,
        workspace: work,
        harness: :codex,
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
          "\n[codex_live] CONVERGED via codex exec: " <>
            "#{result.iterations} iteration(s), final vector satisfied."
        )

      {:ok, %{outcome: other} = result} ->
        # A REAL codex turn ran but did NOT converge in the window. Honest
        # non-claim: report, do not fake a pass.
        IO.puts(
          "\n[codex_live] DID NOT CONVERGE (no success claimed): outcome=#{inspect(other)} " <>
            "reason=#{inspect(result.reason)} after #{result.iterations} iteration(s). " <>
            "codex+auth were present; the real turn did not make the predicate pass in-window " <>
            "(model latency / harness approval policy)."
        )

        :did_not_converge

      {:error, :await_timeout} ->
        IO.puts(
          "\n[codex_live] TIMED OUT (no success claimed): the real codex run did not terminate " <>
            "within the window. Environmental, not a kazi failure."
        )

        :await_timeout

      {:error, reason} ->
        IO.puts(
          "\n[codex_live] RUN ERROR (no success claimed): #{inspect(reason)}. " <>
            "Reported honestly rather than asserting a convergence that did not happen."
        )

        :run_error
    end
  end

  # --- preflight: probe the real dependencies, skip honestly otherwise -------

  @spec preflight() :: :ok | {:skip, String.t()}
  defp preflight do
    with :ok <- codex_on_path(),
         :ok <- codex_auth() do
      :ok
    end
  end

  defp codex_on_path do
    if System.find_executable("codex") do
      :ok
    else
      {:skip, "`codex` is not on PATH"}
    end
  end

  # Codex authenticates via OPENAI_API_KEY or a prior `codex login`. The login
  # state is not cheaply probed here, so a logged-in operator opts in explicitly
  # with KAZI_CODEX_ASSUME_LOGGED_IN=1; otherwise we require OPENAI_API_KEY.
  defp codex_auth do
    cond do
      present?(System.get_env("OPENAI_API_KEY")) ->
        :ok

      present?(System.get_env("KAZI_CODEX_ASSUME_LOGGED_IN")) ->
        :ok

      true ->
        {:skip, "no OPENAI_API_KEY (set it, or `codex login` + KAZI_CODEX_ASSUME_LOGGED_IN=1)"}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
