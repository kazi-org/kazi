defmodule Kazi.Scheduler.IntegrationTest do
  @moduledoc """
  T21.5 acceptance (ADR-0027 step 4): collective integration + merge convergence.

  With a STUB integrator (no real git/gh): converged partitions integrate in a
  SAFE ORDER; a simulated CROSS-PARTITION conflict re-dispatches the affected
  partition; the collective is green ONLY when the merged whole is. The integrator
  seam mirrors how `Kazi.Runtime` injects its integrator/deploy seams, so the
  whole test is hermetic.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Scheduler.Integration

  # A partition stub carrying just the stable lease `:key` the safe order + the
  # request use. (Real runs pass a `Kazi.Scheduler.Partitioner`.)
  defp part(key), do: %{key: key}

  describe "safe order" do
    test "partitions integrate one at a time in deterministic key order" do
      test_pid = self()

      # Record the order each partition is merged, and the base state it saw.
      integrator = fn request, _opts ->
        send(test_pid, {:merged, request.key, request.already_merged})
        {:ok, %{pr: request.key}}
      end

      # Input order is c, a, b; the default safe order is by key ⇒ a, b, c.
      entries = [part("c"), part("a"), part("b")]

      assert {:ok, result} = Integration.integrate(entries, integrator: integrator)

      assert result.collective == :converged
      assert Enum.map(result.integrated, fn {p, _refs} -> p.key end) == ["a", "b", "c"]

      # Each merge saw the EXACT set of already-merged keys before it — proving the
      # serial join advances the base one partition at a time.
      assert_receive {:merged, "a", []}
      assert_receive {:merged, "b", ["a"]}
      assert_receive {:merged, "c", merged_before_c}
      assert Enum.sort(merged_before_c) == ["a", "b"]
    end

    test "a custom :order_fun overrides the safe order" do
      test_pid = self()
      integrator = fn request, _opts -> send(test_pid, {:merged, request.key}) && {:ok, %{}} end

      # Reverse-key order.
      order_fun = fn %{key: k} -> {0, -byte_size(k), k} end

      assert {:ok, _result} =
               Integration.integrate([part("aaa"), part("b"), part("cc")],
                 integrator: integrator,
                 order_fun: order_fun
               )

      assert_receive {:merged, "aaa"}
      assert_receive {:merged, "cc"}
      assert_receive {:merged, "b"}
    end
  end

  describe "clean integration (no conflicts)" do
    test "every partition merges ⇒ collective converged, no conflicts/redispatch" do
      integrator = fn request, _opts ->
        {:ok, %{pr: request.key, merge_commit: "sha-#{request.key}"}}
      end

      assert {:ok, result} =
               Integration.integrate([part("a"), part("b")], integrator: integrator)

      assert result.collective == :converged
      assert length(result.integrated) == 2
      assert result.conflicts == []
      assert result.redispatched == []
    end

    test "an empty converged set integrates vacuously (collective converged)" do
      assert {:ok, result} = Integration.integrate([], integrator: fn _r, _o -> {:ok, %{}} end)
      assert result.collective == :converged
      assert result.integrated == []
    end
  end

  describe "cross-partition conflict ⇒ re-dispatch" do
    test "a conflicting partition is re-dispatched and re-merged; collective green" do
      test_pid = self()

      # Partition "b" conflicts on its FIRST merge attempt, then merges cleanly on
      # the second (simulating: re-dispatch rebased it onto the advanced base).
      {:ok, attempts} = Agent.start_link(fn -> %{} end)

      integrator = fn request, _opts ->
        n =
          Agent.get_and_update(attempts, fn m ->
            {Map.get(m, request.key, 0) + 1, Map.update(m, request.key, 1, &(&1 + 1))}
          end)

        if request.key == "b" and n == 1 do
          # signal a cross-partition conflict via an error tuple
          {:error, {:conflict, :overlapping_edit}}
        else
          {:ok, %{pr: request.key}}
        end
      end

      redispatcher = fn part ->
        send(test_pid, {:redispatched, part.key})
        :converged
      end

      capture_log(fn ->
        assert {:ok, result} =
                 Integration.integrate([part("a"), part("b"), part("c")],
                   integrator: integrator,
                   redispatcher: redispatcher
                 )

        send(test_pid, {:result, result})
      end)

      assert_receive {:result, result}
      # The merged whole is green: "b" re-dispatched and merged on retry.
      assert result.collective == :converged
      assert result.conflicts == []
      assert Enum.map(result.integrated, fn {p, _} -> p.key end) == ["a", "b", "c"]
      # "b" was re-dispatched exactly once (attempt 1 conflicted, attempt 2 merged).
      assert result.redispatched == [{part("b"), 2}]
      assert_receive {:redispatched, "b"}
    end

    test "the conflict signal via {:ok, %{conflict: true}} also re-dispatches" do
      {:ok, seen} = Agent.start_link(fn -> false end)

      integrator = fn
        %{key: "x"}, _opts ->
          if Agent.get_and_update(seen, fn s -> {s, true} end) do
            {:ok, %{pr: "x"}}
          else
            {:ok, %{conflict: true}}
          end

        _req, _opts ->
          {:ok, %{}}
      end

      capture_log(fn ->
        {:ok, r} = Integration.integrate([part("x")], integrator: integrator)
        send(self(), {:result, r})
      end)

      assert_received {:result, result}
      assert result.collective == :converged
      assert result.redispatched == [{part("x"), 2}]
    end
  end

  describe "collective is green ONLY when the merged whole is" do
    test "an unresolvable conflict exhausts the budget ⇒ collective stuck" do
      # "b" conflicts on EVERY attempt; re-dispatch never resolves it.
      integrator = fn
        %{key: "b"}, _opts -> {:error, {:conflict, :stubborn}}
        req, _opts -> {:ok, %{pr: req.key}}
      end

      capture_log(fn ->
        assert {:ok, result} =
                 Integration.integrate([part("a"), part("b")],
                   integrator: integrator,
                   redispatcher: fn _p -> :converged end,
                   max_attempts: 3
                 )

        # The whole is NOT green: "a" merged but "b" never could.
        assert result.collective == :stuck
        assert [{%{key: "a"}, _}] = result.integrated
        assert [{%{key: "b"}, {:conflict, _}}] = result.conflicts
      end)
    end

    test "a re-dispatch that fails to re-converge leaves the partition conflicted" do
      integrator = fn
        %{key: "b"}, _opts -> {:error, {:conflict, :still}}
        req, _opts -> {:ok, %{pr: req.key}}
      end

      # Re-dispatch reports :stuck — the partition did not re-converge, so the
      # conflict stands and the collective is not green.
      capture_log(fn ->
        assert {:ok, result} =
                 Integration.integrate([part("a"), part("b")],
                   integrator: integrator,
                   redispatcher: fn _p -> :stuck end
                 )

        assert result.collective == :stuck
        assert [{%{key: "b"}, {:redispatch_failed, :stuck}}] = result.conflicts
      end)
    end

    test "a hard (non-conflict) integrator error is not retried; collective stuck" do
      test_pid = self()

      integrator = fn
        %{key: "b"}, _opts -> {:error, :auth_failed}
        req, _opts -> {:ok, %{pr: req.key}}
      end

      redispatcher = fn p -> send(test_pid, {:redispatched, p.key}) && :converged end

      assert {:ok, result} =
               Integration.integrate([part("a"), part("b")],
                 integrator: integrator,
                 redispatcher: redispatcher
               )

      assert result.collective == :stuck
      assert [{%{key: "b"}, :auth_failed}] = result.conflicts
      # A hard error never re-dispatches.
      refute_received {:redispatched, "b"}
      assert result.redispatched == []
    end

    test "max_attempts bounds the re-dispatch loop" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      integrator = fn %{key: "b"}, _opts ->
        Agent.update(calls, &(&1 + 1))
        {:error, {:conflict, :never}}
      end

      capture_log(fn ->
        assert {:ok, result} =
                 Integration.integrate([part("b")],
                   integrator: integrator,
                   redispatcher: fn _p -> :converged end,
                   max_attempts: 2
                 )

        assert result.collective == :stuck
      end)

      # Exactly max_attempts merge attempts (1 initial + 1 retry).
      assert Agent.get(calls, & &1) == 2
    end
  end

  describe "integrator contract" do
    test "a raising integrator is contained as a hard error (collective stuck)" do
      integrator = fn _req, _opts -> raise "boom" end

      assert {:ok, result} =
               Integration.integrate([part("a")], integrator: integrator)

      assert result.collective == :stuck
      assert [{%{key: "a"}, {:integrator_raised, _}}] = result.conflicts
    end

    test "a malformed integrator result is a hard error" do
      integrator = fn _req, _opts -> :not_a_tuple end

      assert {:ok, result} = Integration.integrate([part("a")], integrator: integrator)
      assert result.collective == :stuck
      assert [{%{key: "a"}, {:bad_integrator_result, :not_a_tuple}}] = result.conflicts
    end
  end
end
