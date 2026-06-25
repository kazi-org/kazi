defmodule Kazi.MetricTest do
  @moduledoc """
  Tier 2 (real boundary): `Kazi.Metric` runs actual commands via `System.cmd` in a
  temp workspace and extracts the numeric signal a `:ratchet` compares (T32.3).
  """
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_metric_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp emit(out), do: %{cmd: "sh", args: ["-c", "printf '%s' '#{out}'"]}

  describe "scalar stdout (no :path)" do
    test "parses a bare number off stdout", %{workspace: ws} do
      assert {:ok, 81.5, _} = Kazi.Metric.signal(emit("81.5"), ws)
    end

    test "tolerates surrounding whitespace/newlines", %{workspace: ws} do
      config = %{cmd: "sh", args: ["-c", "printf '  42\\n'"]}
      assert {:ok, 42.0, _} = Kazi.Metric.signal(config, ws)
    end

    test "non-numeric stdout is an :error, never a silent zero", %{workspace: ws} do
      assert {:error, {:metric_not_a_number, _}} = Kazi.Metric.signal(emit("not a number"), ws)
    end
  end

  describe "json stdout (:path)" do
    test "extracts a number at the path", %{workspace: ws} do
      config = Map.put(emit(~s({"totals":{"percent":73.2}})), :path, "$.totals.percent")
      assert {:ok, 73.2, _} = Kazi.Metric.signal(config, ws)
    end

    test "a findings array yields its count", %{workspace: ws} do
      config = Map.put(emit(~s({"runs":[{"results":[{},{}]}]})), :path, "$.runs[0].results")
      assert {:ok, 2, _} = Kazi.Metric.signal(config, ws)
    end

    test "invalid json is an :error", %{workspace: ws} do
      config = Map.put(emit("nope"), :path, "$.x")
      assert {:error, :metric_invalid_json} = Kazi.Metric.signal(config, ws)
    end

    test "an unresolved path is an :error", %{workspace: ws} do
      config = Map.put(emit(~s({"a":1})), :path, "$.missing")
      assert {:error, {:path_missing, "missing", _}} = Kazi.Metric.signal(config, ws)
    end
  end

  describe "command failures" do
    test "a missing binary is an :error (not a number)", %{workspace: ws} do
      assert {:error, {:metric_unrunnable, _}} =
               Kazi.Metric.signal(%{cmd: "definitely-not-a-real-binary-xyz"}, ws)
    end

    test "a non-zero metric exit is an :error", %{workspace: ws} do
      assert {:error, {:metric_exit, 1, _}} =
               Kazi.Metric.signal(%{cmd: "sh", args: ["-c", "echo 5; exit 1"]}, ws)
    end

    test "a missing cmd is an :error", %{workspace: ws} do
      assert {:error, :missing_metric_cmd} = Kazi.Metric.signal(%{}, ws)
    end

    test "an overrunning command is killed and reported as a timeout", %{workspace: ws} do
      config = %{cmd: "sh", args: ["-c", "sleep 5; echo 1"], timeout_ms: 50}
      assert {:error, {:metric_timeout_ms, 50}} = Kazi.Metric.signal(config, ws)
    end
  end
end
