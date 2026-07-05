defmodule Kazi.Integration.TranscriptSinkTest do
  @moduledoc """
  Tier 2 — the end-to-end proof for T46.3 (ADR-0057 decision 3): a real `kazi
  apply` run through `Kazi.CLI.run/2` (the same entry point every real user
  hits) writes a redacted, per-run `transcript.jsonl` at the path recorded on
  its `runs` registry row. `Kazi.Sink.TranscriptTest` already pins the tee
  function in isolation; this test proves it is actually wired into the live
  dispatch + runtime path, not just callable on its own.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.Run
  alias Kazi.Repo

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a converging `kazi apply` run writes a redacted transcript.jsonl at the registered path",
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

    run = Repo.get_by!(Run, goal_ref: "transcript-sink-wiring-fixture")

    assert run.transcript_sink_path
    assert String.starts_with?(run.transcript_sink_path, sinks_dir)
    assert File.exists?(run.transcript_sink_path)

    events =
      run.transcript_sink_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(events, &(&1["type"] == "text" && &1["text"] == "plain harness stdout"))

    content = File.read!(run.transcript_sink_path)
    refute content =~ "s3cr3t-token"
    assert content =~ "[REDACTED]"
  end

  defp write_goal_file(tmp_dir, work) do
    path = Path.join(tmp_dir, "goal.toml")

    File.write!(path, """
    id = "transcript-sink-wiring-fixture"
    name = "T46.3 transcript-sink wiring fixture"

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
    echo "plain harness stdout"
    echo "DATABASE_URL=postgres://app:s3cr3t-token@db:5432/prod"
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end
