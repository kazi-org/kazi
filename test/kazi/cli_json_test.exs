defmodule Kazi.CLIJsonTest do
  @moduledoc """
  T15.1 (ADR-0023 decision 1): the `--json` output framework + the
  non-interactive guarantee.

  Tier 1 pins the argv boundary — `--json` is a boolean switch threaded into the
  parsed command (`Kazi.CLI.parse/1`).

  Tier 2 drives the render seam through the REAL CLI exec core (`Kazi.CLI.run/2`)
  and `ExUnit.CaptureIO`, exactly as `Kazi.CLIAuthoringTest` does:

    * `--version --json` emits VALID JSON only (no human prose), proving the seam
      end-to-end; non-`--json` output is unchanged.
    * `propose --json` is NON-INTERACTIVE: an underspecified idea (which would
      prompt) errors LOUDLY as a JSON object on stdout with a non-zero exit
      instead of blocking on stdin; it never reads stdin.

  HERMETIC: no real `claude`, no network. The propose path threads the same
  `inject_opts` test seam (`:harness`/`:ask`) the authoring tests use.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{ReadModel, Repo}
  alias Kazi.ReadModel.ProposedGoal

  # The same injectable stub the authoring tests use: a fixed JSON proposal in
  # the result envelope, no real claude, no network.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result: ~s({
           "name": "CLI json e2e",
           "predicates": [
             {"id": "code", "provider": "test_runner",
              "config": {"cmd": "sh", "args": ["-c", "true"]}},
             {"id": "live", "provider": "http_probe",
              "config": {"url": "http://127.0.0.1/healthz", "expect_status": 200}}
           ]
         })
       }}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Tier 1 — `--json` argv boundary
  # ===========================================================================

  describe "parse/1 — --json switch" do
    test "--json is a recognized boolean flag on version" do
      assert {:version, flags} = Kazi.CLI.parse(["--version", "--json"])
      assert flags[:json] == true
    end

    test "propose carries --json through to its opts" do
      assert {:propose, "an idea", opts} =
               Kazi.CLI.parse(["propose", "an idea", "--json"])

      assert opts[:json] == true
    end

    test "without --json the propose flag defaults to false (human is the default)" do
      assert {:propose, "an idea", opts} = Kazi.CLI.parse(["propose", "an idea"])
      assert opts[:json] == false
    end
  end

  # ===========================================================================
  # Tier 2 — the render seam end-to-end (--version proves it)
  # ===========================================================================

  describe "run/2 — --version --json emits valid JSON only" do
    test "emits a single JSON object (no human prose) and exits 0" do
      out = capture_io(fn -> assert Kazi.CLI.run(["--version", "--json"]) == 0 end)

      # VALID JSON only: the whole stdout decodes as one object, with no prose.
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert is_map(payload)
      assert payload["kazi"] =~ ~r/^\d+\.\d+\.\d+/
      assert payload["schema_version"] == 1
      refute out =~ "kazi 0."
      refute String.starts_with?(out, "kazi ")
    end

    test "without --json the human output is unchanged" do
      out = capture_io(fn -> assert Kazi.CLI.run(["--version"]) == 0 end)
      assert out =~ ~r/^kazi \d+\.\d+\.\d+/
      assert {:error, _} = Jason.decode(String.trim(out))
    end
  end

  # ===========================================================================
  # Tier 2 — the non-interactive guarantee (propose under --json)
  # ===========================================================================

  describe "run/2 — --json is non-interactive" do
    test "an underspecified idea under --json errors as JSON (non-zero), never blocks" do
      # No injected :ask and not --yes: interactively this WOULD prompt. Under
      # --json it must error loudly on stdout and return non-zero instead of
      # blocking on stdin — captured WITHOUT supplying any stdin input.
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["propose", "add a widgets feature", "--json"],
                   harness: StubHarness,
                   # A TTY is "attached" — proves --json overrides the TTY check
                   # and stays non-interactive (no terminal prompt).
                   tty: true
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "interactive"
      assert payload["error"] =~ "--yes"
      # No proposal was persisted (it refused rather than guessing).
      assert ReadModel.list_proposed_goals(status: "proposed") == []
    end

    test "--json --yes drafts best-effort without prompting (proves headless path)" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["propose", "ship a healthz endpoint", "--json", "--yes"],
                   harness: StubHarness
                 ) == 0
        end)

      # Human report still prints today (propose's JSON schema is T15.2) — the
      # point here is the NON-INTERACTIVE path completed headlessly with exit 0
      # and persisted the proposal without reading stdin.
      assert out =~ "PROPOSED"

      assert [%ProposedGoal{status: "proposed"} = row] =
               ReadModel.list_proposed_goals(status: "proposed")

      assert row.idea == "ship a healthz endpoint"
    end
  end
end
