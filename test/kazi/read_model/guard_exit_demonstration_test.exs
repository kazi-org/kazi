defmodule Kazi.ReadModel.GuardExitDemonstrationTest do
  @moduledoc """
  DEMONSTRATION (#1483 ground (b), L-0053): does an exit arising OUTSIDE the
  guarded fun's own execution reach a NON-TRAPPING caller through `Task.async`'s
  link, killing it — or does `Kazi.ReadModel.Guard.run/3` contain it?

  This test DEMONSTRATES; it does not fix. Guard sits under every registry /
  projection write and the boot migration, so any remedy gets its own PR and
  blast-radius review.

  ## Why this exit is the one that matters

  `Guard.run/3` wraps the fun in `try/rescue/catch`, which converts every failure
  the fun RAISES — exceptions (`rescue`), and `:throw`/`:exit`/`:error` raised in
  the fun's own execution (`catch kind, reason`). Those are already contained.

  What `try/catch` cannot convert is an **asynchronous exit signal**: a linked
  process dying delivers a signal that kills the process outright rather than
  unwinding through `catch`. `Task.async/1` links the task to its caller, so such
  a signal propagates task → caller. A caller that traps exits survives it; a
  caller that does not is killed. `KaziWeb.MissionControlLive` is an ordinary
  LiveView and does not trap.

  The two arms below differ ONLY in `Process.flag(:trap_exit, ...)`, which
  isolates the link as the single variable.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.Guard

  # Runs `Guard.run/3` inside a monitored caller so the test process survives to
  # observe whether that caller lived or died. The guarded fun triggers an exit
  # arising OUTSIDE its own execution: a linked process dies, delivering an async
  # signal to the task. `catch kind, reason` cannot intercept that.
  defp caller_outcome(trap_exits?) do
    test = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        if trap_exits?, do: Process.flag(:trap_exit, true)

        result =
          Guard.run(
            "exit-demonstration",
            fn ->
              spawn_link(fn -> exit(:linked_process_died) end)
              # Stay alive long enough for the signal to arrive; if the guard
              # contained it we would return this value instead.
              Process.sleep(1_000)
              :fun_completed_normally
            end,
            5_000
          )

        send(test, {:caller_survived, result})
      end)

    receive do
      {:caller_survived, result} ->
        # Drain the DOWN so it cannot leak into the next assertion.
        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          1_000 -> :ok
        end

        {:survived, result}

      {:DOWN, ^ref, :process, _, :normal} ->
        {:died, :normal}

      {:DOWN, ^ref, :process, _, reason} ->
        {:died, reason}
    after
      10_000 -> {:timeout, nil}
    end
  end

  describe "an exit arising OUTSIDE the fun's execution (#1483 ground (b))" do
    test "TRAPPING caller: survives with the honest error tuple (the contained case)" do
      assert {:survived, {:error, :read_model_unavailable}} = caller_outcome(true)
    end

    @tag :known_defect
    test "NON-TRAPPING caller: is KILLED — pins the DEMONSTRATED defect (#1483 ground (b))" do
      # DEMONSTRATED 2026-07-20, not theorised: the only difference from the
      # trapping arm above is Process.flag(:trap_exit, true), and it flips the
      # outcome from "survives with the honest error tuple" to "dead".
      #
      # This assertion deliberately pins the CURRENT, DEFECTIVE behaviour so the
      # gap cannot regress silently and so the eventual fix has to prove it
      # changed something. WHEN GUARD IS FIXED, INVERT THIS: the expectation
      # becomes {:survived, {:error, :read_model_unavailable}}, matching the
      # trapping arm. Do not delete the test — flip it.
      assert {:died, :linked_process_died} = caller_outcome(false)
    end
  end

  describe "control: failures the fun RAISES are contained (regression pin)" do
    test "a raised exception is converted, caller survives" do
      assert {:survived, {:error, :read_model_unavailable}} =
               caller_outcome_raising(fn -> raise "boom" end)
    end

    test "an exit RAISED by the fun itself is caught and converted, caller survives" do
      assert {:survived, {:error, :read_model_unavailable}} =
               caller_outcome_raising(fn -> exit(:raised_in_fun) end)
    end
  end

  # Same monitored-caller harness, but the fun fails in a way `try/rescue/catch`
  # DOES convert — the contrast that shows the gap is specific to async signals.
  defp caller_outcome_raising(fun) do
    test = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        result = Guard.run("exit-demonstration-control", fun, 5_000)
        send(test, {:caller_survived, result})
      end)

    receive do
      {:caller_survived, result} ->
        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          1_000 -> :ok
        end

        {:survived, result}

      {:DOWN, ^ref, :process, _, reason} ->
        {:died, reason}
    after
      10_000 -> {:timeout, nil}
    end
  end
end
