defmodule Kazi.Runtime.BusMirrorTest do
  @moduledoc """
  T51.5 (ADR-0067 point 1): the run-lifecycle mirror's projection + fire-and-
  forget contract in isolation. A capturing poster (the `:run_mirror_poster`
  seam) stands in for a live daemon so we assert the mirrored facts' CONTENT;
  the daemon-down path is exercised against the real `Kazi.Bus.post/3` with no
  daemon, asserting it swallows to `:ok` and never raises.
  """
  # Mutates the global :run_mirror_poster seam -> not async.
  use ExUnit.Case, async: false

  alias Kazi.Runtime.BusMirror
  alias Kazi.{PredicateResult, PredicateVector}

  defp capture do
    test = self()

    fn kind, text, opts ->
      send(test, {:posted, kind, text, opts})
      :ok
    end
  end

  defp with_poster(fun) do
    Application.put_env(:kazi, :run_mirror_poster, fun)
    on_exit(fn -> Application.delete_env(:kazi, :run_mirror_poster) end)
  end

  defp vector(pass, fail) do
    results =
      Map.new(
        Enum.map(1..pass//1, &{:"p#{&1}", PredicateResult.pass()}) ++
          Enum.map(1..fail//1, &{:"f#{&1}", PredicateResult.fail()})
      )

    PredicateVector.new(results)
  end

  describe "content" do
    setup do
      with_poster(capture())
      :ok
    end

    test "started carries the goal ref and posts to the per-run topic" do
      BusMirror.started("my-goal", "abcdef1234567890", "sess-1")

      assert_receive {:posted, "fact", "started my-goal", opts}
      assert opts[:topic] == "run:abcdef12"
      assert opts[:session_name] == "sess-1"
    end

    test "iteration reports index and pass/total" do
      BusMirror.iteration("abcdef1234567890", "sess-1", %{
        iteration: 3,
        vector: vector(5, 3),
        regressions: []
      })

      assert_receive {:posted, "fact", "iter 3: 5/8 passing", opts}
      assert opts[:topic] == "run:abcdef12"
    end

    test "iteration appends a regression count when predicates went green->red" do
      BusMirror.iteration("run00000", "s", %{
        iteration: 4,
        vector: vector(2, 2),
        regressions: [:p1, :p2]
      })

      assert_receive {:posted, "fact", "iter 4: 2/4 passing (2 regressed)", _opts}
    end

    test "terminal maps each outcome to an honest verdict" do
      BusMirror.terminal(
        "g",
        "run00000",
        "s",
        {:ok, %{outcome: :converged, vector: vector(3, 0), iterations: 2}}
      )

      assert_receive {:posted, "fact", "converged g (3/3 passing, 2 iters)", _}

      BusMirror.terminal(
        "g",
        "run00000",
        "s",
        {:ok, %{outcome: :stopped, reason: :stuck, vector: vector(1, 2), iterations: 9}}
      )

      assert_receive {:posted, "fact", "stuck g (1/3 passing, 9 iters)", _}

      BusMirror.terminal(
        "g",
        "run00000",
        "s",
        {:ok,
         %{outcome: :over_budget, reason: :max_iterations, vector: vector(2, 1), iterations: 40}}
      )

      assert_receive {:posted, "fact", "over_budget g (2/3 passing, 40 iters)", _}

      BusMirror.terminal("g", "run00000", "s", {:error, :await_timeout})
      assert_receive {:posted, "fact", "error g", _}
    end

    test "terminated carries the goal ref and bounded reason on the per-run topic" do
      BusMirror.terminated("my-goal", "abcdef1234567890", "sess-1", :killed)

      assert_receive {:posted, "fact", "terminated my-goal (killed)", opts}
      assert opts[:topic] == "run:abcdef12"
      assert opts[:session_name] == "sess-1"
    end

    test "terminated bounds a large reason term so it can never blow the size budget" do
      BusMirror.terminated("g", "run00000", "s", String.duplicate("x", 500))

      assert_receive {:posted, "fact", text, _}
      assert String.starts_with?(text, "terminated g (")
      # 80-char reason bound + the "terminated g (" prefix + ")" suffix.
      assert String.length(text) <= 100
    end
  end

  describe "fire-and-forget contract" do
    test "a malformed iteration payload is a silent no-op, never a post" do
      with_poster(capture())
      assert BusMirror.iteration("run00000", "s", %{not: :an_iteration}) == :ok
      refute_receive {:posted, _, _, _}
    end

    test "started/terminal/terminated swallow a poster that raises and still return :ok" do
      with_poster(fn _k, _t, _o -> raise "boom" end)

      assert BusMirror.started("g", "run00000", "s") == :ok
      assert BusMirror.terminal("g", "run00000", "s", {:ok, %{outcome: :converged}}) == :ok
      assert BusMirror.terminated("g", "run00000", "s", :killed) == :ok
    end

    test "against the REAL Kazi.Bus.post with NO daemon, every post returns :ok and never raises" do
      # No :run_mirror_poster override -> the default &Kazi.Bus.post/3, which
      # returns {:error, :no_daemon} offline. The mirror must swallow it.
      Application.delete_env(:kazi, :run_mirror_poster)

      assert BusMirror.started("g", "run00000", "sess") == :ok

      assert BusMirror.iteration("run00000", "sess", %{
               iteration: 0,
               vector: vector(1, 0),
               regressions: []
             }) == :ok

      assert BusMirror.terminal(
               "g",
               "run00000",
               "sess",
               {:ok, %{outcome: :converged, vector: vector(1, 0), iterations: 1}}
             ) == :ok

      assert BusMirror.terminated("g", "run00000", "sess", :killed) == :ok
    end
  end
end
