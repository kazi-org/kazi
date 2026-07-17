defmodule Kazi.ReadModel.GuardTest do
  # Pins the "kazi never hangs on its own telemetry" invariant (lore
  # L-0049): every read-model touch on the run path is bounded — a wedged
  # write degrades to {:error, :read_model_unavailable} within the deadline
  # instead of blocking the reconcile loop indefinitely.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.ReadModel.Guard

  test "a healthy write passes its result through untouched" do
    assert Guard.run("test", fn -> {:ok, :written} end) == {:ok, :written}
  end

  test "a blocked write times out within the deadline instead of hanging" do
    {elapsed_us, {result, log}} =
      :timer.tc(fn ->
        with_log(fn ->
          Guard.run("blocked write", fn -> Process.sleep(:infinity) end, 100)
        end)
      end)

    assert result == {:error, :read_model_unavailable}
    assert elapsed_us < 5_000_000, "guard must return promptly, not hang"
    assert log =~ "blocked write"
    assert log =~ "continuing without persistence"
  end

  test "a crashing write degrades to unavailable instead of killing the caller" do
    {result, log} =
      with_log(fn -> Guard.run("crashing write", fn -> raise "boom" end) end)

    assert result == {:error, :read_model_unavailable}
    assert log =~ "crashing write"
  end

  test "a throwing write degrades to unavailable" do
    {result, _log} =
      with_log(fn -> Guard.run("throwing write", fn -> exit(:kaboom) end) end)

    assert result == {:error, :read_model_unavailable}
  end
end
