defmodule Kazi.Sink.EventsTest do
  @moduledoc """
  T46.2 (ADR-0057 decision 3): `Kazi.Sink.Events` in isolation (append/read,
  redaction, torn-line tolerance, and the retention sweep), plus the
  end-to-end wiring proof (Tier 2, mirroring `Kazi.Integration.TranscriptSinkTest`
  for T46.3): a real `kazi apply` run through `Kazi.CLI.run/2` — the same entry
  point every real user hits — writes a per-run `events.jsonl` at the path
  recorded on its `runs` registry row, whose per-iteration vectors match the
  read-model's `iterations` rows for the same goal.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo
  alias Kazi.Sink.Events

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # =============================================================================
  # Tier 1 — append/read in isolation
  # =============================================================================

  describe "append/3 and read/1" do
    test "nil path is a no-op", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "events.jsonl")
      assert :ok = Events.append(nil, %{"type" => "iteration"})
      refute File.exists?(path)
    end

    test "appends events as JSONL, in order", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "events.jsonl")

      Events.append(path, %{"type" => "iteration", "iteration" => 0})
      Events.append(path, %{"type" => "iteration", "iteration" => 1})

      assert [%{"iteration" => 0}, %{"iteration" => 1}] = Events.read(path)
    end

    test "a seeded secret is redacted on disk", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "events.jsonl")

      Events.append(path, %{
        "type" => "iteration",
        "action_params" => %{"note" => "DATABASE_URL=postgres://app:s3cr3t@db:5432/prod"}
      })

      content = File.read!(path)
      refute content =~ "s3cr3t"
      assert content =~ "[REDACTED]"
    end

    test "a torn final line is dropped, earlier lines still read back", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "events.jsonl")

      Events.append(path, %{"type" => "iteration", "iteration" => 0})
      Events.append(path, %{"type" => "iteration", "iteration" => 1})
      File.write!(path, ~s({"type":"iteration","iteration":2,"trunc), [:append])

      assert [%{"iteration" => 0}, %{"iteration" => 1}] = Events.read(path)
    end

    test "reading a missing file returns an empty list", %{tmp_dir: tmp_dir} do
      assert Events.read(Path.join(tmp_dir, "nope.jsonl")) == []
    end
  end

  # =============================================================================
  # Retention sweep
  # =============================================================================

  describe "sweep/2" do
    setup %{tmp_dir: tmp_dir} do
      sinks_dir = Path.join(tmp_dir, "sinks")
      File.mkdir_p!(sinks_dir)
      {:ok, sinks_dir: sinks_dir}
    end

    test "drops a run directory aged past max_age_seconds", %{sinks_dir: sinks_dir} do
      run_dir = write_run_dir(sinks_dir, "old-run", "small")
      old_time = System.os_time(:second) - 3600
      File.touch!(Path.join(run_dir, "events.jsonl"), old_time)

      assert Events.sweep(sinks_dir, max_age_seconds: 60, max_bytes: 999_999) == ["old-run"]
      refute File.exists?(run_dir)
    end

    test "drops a run directory over max_bytes", %{sinks_dir: sinks_dir} do
      run_dir = write_run_dir(sinks_dir, "big-run", String.duplicate("x", 200))

      assert Events.sweep(sinks_dir, max_age_seconds: 999_999, max_bytes: 50) == ["big-run"]
      refute File.exists?(run_dir)
    end

    test "never touches a live run's directory regardless of age or size", %{
      sinks_dir: sinks_dir
    } do
      run_dir = write_run_dir(sinks_dir, "live-run", String.duplicate("x", 200))
      old_time = System.os_time(:second) - 3600
      File.touch!(Path.join(run_dir, "events.jsonl"), old_time)

      assert Events.sweep(sinks_dir,
               max_age_seconds: 60,
               max_bytes: 50,
               live_run_ids: ["live-run"]
             ) == []

      assert File.exists?(run_dir)
    end

    test "keeps a fresh, small run directory untouched", %{sinks_dir: sinks_dir} do
      run_dir = write_run_dir(sinks_dir, "fresh-run", "small")

      assert Events.sweep(sinks_dir, max_age_seconds: 999_999, max_bytes: 999_999) == []
      assert File.exists?(run_dir)
    end

    test "sweeping a missing sinks_dir returns an empty list", %{tmp_dir: tmp_dir} do
      assert Events.sweep(Path.join(tmp_dir, "does-not-exist")) == []
    end

    defp write_run_dir(sinks_dir, run_id, content) do
      run_dir = Path.join(sinks_dir, run_id)
      File.mkdir_p!(run_dir)
      File.write!(Path.join(run_dir, "events.jsonl"), content)
      run_dir
    end
  end

  # =============================================================================
  # Tier 2 — end-to-end wiring through Kazi.CLI.run/2
  # =============================================================================

  test "a converging `kazi apply` run writes events.jsonl matching the read-model rows",
       %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    sinks_dir = Path.join(tmp_dir, "sinks")

    goal_file = write_goal_file(tmp_dir, work)
    harness_stub = write_harness_stub(tmp_dir)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work],
          adapter_opts: [command: harness_stub],
          sinks_dir: sinks_dir,
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0

    run = Repo.get_by!(Run, goal_ref: "events-sink-wiring-fixture")

    assert run.events_sink_path
    assert String.starts_with?(run.events_sink_path, sinks_dir)
    assert File.exists?(run.events_sink_path)

    events = Events.read(run.events_sink_path)
    assert length(events) > 0
    assert Enum.all?(events, &(&1["type"] == "iteration"))

    iterations =
      Kazi.ReadModel.Iteration
      |> where(goal_ref: "events-sink-wiring-fixture")
      |> Repo.all()
      |> Map.new(&{&1.iteration_index, &1})

    for event <- events do
      iteration = Map.fetch!(iterations, event["iteration"])
      assert event["converged"] == iteration.converged
      assert event["predicates"] == iteration.predicate_vector
      assert event["regressions"] == iteration.regressions
      assert event["context"] == iteration.context
      assert event["tools"] == iteration.tools
    end

    assert Enum.any?(events, & &1["converged"])
    refute RunRegistry.stale?(run)
  end

  defp write_goal_file(tmp_dir, work) do
    path = Path.join(tmp_dir, "goal.toml")

    File.write!(path, """
    id = "events-sink-wiring-fixture"
    name = "T46.2 events-sink wiring fixture"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp write_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
