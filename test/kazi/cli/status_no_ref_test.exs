defmodule Kazi.CLI.StatusNoRefTest do
  @moduledoc """
  Issue #971: `kazi status` called with NO ref is the pre-upgrade check — it
  lists every run the registry currently considers LIVE (`status ==
  "running"` AND a heartbeat fresher than `Kazi.ReadModel.RunRegistry`'s
  existing staleness window, `stale?/2` / `list_live/1`) instead of erroring
  with "requires a <ref>". An operator runs this before `brew upgrade`/
  reinstalling a burrito-built binary to see what's live and wait it out (see
  `docs/lore.md`, Release / CI / Burrito).

  HERMETIC: the read-model is the test SQLite Sandbox; runs are registered
  directly via `RunRegistry.start/1` (no real harness/process spawned).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp run_attrs(overrides) do
    Map.merge(
      %{
        run_id: "run-#{System.unique_integer([:positive])}",
        pid: "#PID<0.123.0>",
        workspace: "/tmp/ws",
        goal_ref: "goal-live-check",
        harness: "claude",
        model: "claude-sonnet-5"
      },
      overrides
    )
  end

  defp force_heartbeat(run, seconds_ago) do
    stale_heartbeat = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    run
    |> Run.changeset(%{"heartbeat_at" => stale_heartbeat})
    |> Repo.update!()
  end

  describe "parse/1 — status with no ref" do
    test "parses to {:status, nil, opts}, NOT an error" do
      assert {:status, nil, opts} = Kazi.CLI.parse(["status"])
      assert opts[:json] == false

      assert {:status, nil, json_opts} = Kazi.CLI.parse(["status", "--json"])
      assert json_opts[:json] == true
    end
  end

  describe "kazi status --json (no ref)" do
    test "no live runs -> an empty list, exit 0" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["kind"] == "live_runs"
      assert payload["count"] == 0
      assert payload["runs"] == []
    end

    test "a fresh-heartbeat running run is included" do
      attrs = run_attrs(%{goal_ref: "goal-fresh"})
      assert {:ok, _run} = RunRegistry.start(attrs)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["count"] == 1
      assert [row] = payload["runs"]
      assert row["goal_ref"] == "goal-fresh"
      assert row["run_id"] == attrs.run_id
      assert row["status"] == "running"
      assert is_integer(row["heartbeat_age_s"])
      assert row["heartbeat_age_s"] < 90
    end

    test "a stale (old heartbeat) running run is excluded" do
      attrs = run_attrs(%{goal_ref: "goal-stale"})
      assert {:ok, run} = RunRegistry.start(attrs)
      force_heartbeat(run, 200)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["count"] == 0
      assert payload["runs"] == []
    end

    test "a terminal (converged) run is excluded even with a fresh heartbeat" do
      attrs = run_attrs(%{goal_ref: "goal-done"})
      assert {:ok, _run} = RunRegistry.start(attrs)
      assert {:ok, _finished} = RunRegistry.finish(attrs.run_id, "converged")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["count"] == 0
      assert payload["runs"] == []
    end

    test "one live + one stale run -> only the live one is listed" do
      live_attrs = run_attrs(%{goal_ref: "goal-live"})
      assert {:ok, _live} = RunRegistry.start(live_attrs)

      stale_attrs = run_attrs(%{goal_ref: "goal-dead"})
      assert {:ok, dead_run} = RunRegistry.start(stale_attrs)
      force_heartbeat(dead_run, 200)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["status", "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["count"] == 1
      assert [row] = payload["runs"]
      assert row["goal_ref"] == "goal-live"
      assert row["run_id"] == live_attrs.run_id
    end
  end

  describe "kazi status (no ref, human) — the pre-upgrade check's prose surface" do
    test "no live runs prints a clear safe-to-upgrade line" do
      {code, out} =
        with_io(fn -> Kazi.CLI.run(["status"]) end)

      assert code == 0
      assert out =~ "no LIVE runs"
      refute out =~ "schema_version"
    end

    test "a live run is listed by goal_ref and run_id" do
      attrs = run_attrs(%{goal_ref: "goal-human-live"})
      assert {:ok, _run} = RunRegistry.start(attrs)

      {code, out} = with_io(fn -> Kazi.CLI.run(["status"]) end)

      assert code == 0
      assert out =~ "goal-human-live"
      assert out =~ attrs.run_id
    end
  end
end
