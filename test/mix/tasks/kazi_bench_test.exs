defmodule Mix.Tasks.Kazi.BenchTest do
  @moduledoc """
  Hermetic tests for the benchmark mix task (T19.4). They exercise ONLY the
  offline paths — `--help` (usage describing the 3 arms) and `--captures <dir>`
  (aggregating recorded `claude --output-format json` envelopes into the per-arm
  table) — never the live 3-arm run (that needs `claude` on PATH and is T19.5).

  `Mix.shell()` is swapped for the process shell so the task's output is captured
  as `{:mix_shell, :info, [msg]}` messages.
  """
  use ExUnit.Case, async: false

  @captures Path.expand("../../fixtures/bench/captures", __DIR__)

  setup do
    prev = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(prev) end)
    :ok
  end

  defp shell_output do
    receive_all([])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp receive_all(acc) do
    receive do
      {:mix_shell, :info, [msg]} -> receive_all([msg | acc])
    after
      0 -> acc
    end
  end

  test "--help describes the 3 arms and how to run" do
    Mix.Tasks.Kazi.Bench.run(["--help"])
    out = shell_output()

    assert out =~ "A — vanilla"
    assert out =~ "B — kazi WITHOUT the orientation prefix"
    assert out =~ "C — kazi WITH the orientation prefix"
    assert out =~ "THE LIVE RUN IS T19.5"
    assert out =~ "mix kazi.bench"
  end

  test "--captures aggregates recorded envelopes into the per-arm table" do
    Mix.Tasks.Kazi.Bench.run(["--captures", @captures])
    out = shell_output()

    # The table header + one row per arm (A: 1 dispatch, B/C: 3 each).
    assert out =~
             "| Arm | Iterations | Input | Output | Cache-create | Cache-read | Total | Cost (USD) |"

    assert out =~ "| A | 1 |"
    assert out =~ "| B | 3 |"
    assert out =~ "| C | 3 |"
  end

  test "--captures honours an --arms subset" do
    Mix.Tasks.Kazi.Bench.run(["--captures", @captures, "--arms", "C"])
    out = shell_output()

    assert out =~ "| C | 3 |"
    refute out =~ "| A | 1 |"
    refute out =~ "| B | 3 |"
  end

  test "no --captures and no --help points at the maintainer live run (T19.5), runs nothing live" do
    Mix.Tasks.Kazi.Bench.run(["--goal", "x.toml", "--workspace", "/tmp/ws"])
    out = shell_output()

    assert out =~ "run by a maintainer (T19.5)"
    assert out =~ "--captures"
  end
end
