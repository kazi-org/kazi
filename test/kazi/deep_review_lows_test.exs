defmodule Kazi.DeepReviewLowsTest do
  @moduledoc """
  Rollup regression coverage for the Low-severity findings in
  `docs/deep-reviews/001-full-codebase.md` that do not warrant their own file
  (L1, L2, L7, L8, L9, L10, L11, L12, L13; see
  `docs/deep-reviews/001-remediation.goal.toml`'s `lows_regressions` predicate).
  Each `describe` block below is one finding, self-contained and hermetic.
  """

  # Several cases touch the shared Sandbox connection from spawned processes
  # (the real Kazi.Loop / Kazi.Scheduler) or a process-global :telemetry handler
  # (L7) — serialize the whole file rather than reasoning about interleaving.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Kazi.{Action, Budget, Goal, Predicate, PredicateResult, PredicateVector, Repo}
  alias Kazi.Context.StaticGraphSource
  alias Kazi.Coordination.{Lease, LeaseTable}
  alias Kazi.Goal.Loader
  alias Kazi.ReadModel

  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # L1 — needs-cycle detection over a wide diamond DAG must not blow up
  # exponentially (loader.ex validate_no_needs_cycle/1).
  # ===========================================================================

  describe "L1: needs-cycle detection over a diamond lattice" do
    test "a deep diamond needs-lattice loads within a bounded time (no exponential blowup)" do
      levels = 24

      diamond_groups =
        Enum.flat_map(1..levels, fn i ->
          needs = if i == 1, do: ["n0"], else: ["n#{i - 1}_a", "n#{i - 1}_b"]

          [
            %{"id" => "n#{i}_a", "name" => "N#{i}A", "needs" => needs},
            %{"id" => "n#{i}_b", "name" => "N#{i}B", "needs" => needs}
          ]
        end)

      data = %{
        "id" => "l1-diamond",
        "group" => [%{"id" => "n0", "name" => "N0"} | diamond_groups],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      task = Task.async(fn -> Loader.from_map(data) end)

      result =
        case Task.yield(task, 2_000) do
          {:ok, value} ->
            value

          nil ->
            Task.shutdown(task, :brutal_kill)
            :timed_out
        end

      assert {:ok, %Goal{}} = result,
             "expected the diamond needs-lattice to load within 2s; the memoized " <>
               "walk must visit each node once, not exponentially"
    end

    test "a genuine cycle over a diamond-shaped needs graph is still rejected" do
      data = %{
        "id" => "l1-cycle",
        "group" => [
          %{"id" => "a", "name" => "A", "needs" => ["d"]},
          %{"id" => "b", "name" => "B", "needs" => ["a"]},
          %{"id" => "c", "name" => "C", "needs" => ["a"]},
          %{"id" => "d", "name" => "D", "needs" => ["b", "c"]}
        ],
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "cyclic needs chain"
    end
  end

  # ===========================================================================
  # L2 — with_read_model must thread --json through to emit_json_error rather
  # than only ever printing a human stderr line (cli.ex).
  # ===========================================================================

  describe "L2: with_read_model surfaces --json errors via the JSON envelope" do
    test "every with_read_model call site threads opts (no opts-less regression)" do
      # A live repro requires the read-model genuinely unavailable, which in this
      # codebase only happens when the SQLite NIF fails to load (the escript
      # build) — not safely simulable inside `mix test` without corrupting the
      # whole suite's shared connection. This is a deterministic source-level
      # wiring guard: with_read_model/1 (opts-less) must be fully gone, and
      # every call site must use the opts-threading opts_read_model/2 form, so
      # the read-model-unavailable error follows the same --json contract every
      # other load/availability error does.
      source = File.read!(Path.join([File.cwd!(), "lib", "kazi", "cli.ex"]))

      refute source =~ "with_read_model(fn ->",
             "a with_read_model call site regressed to the opts-less form"

      assert source |> String.split("with_read_model(opts, fn ->") |> length() == 12
    end
  end

  # ===========================================================================
  # L7 — build_goal_summary/1 must survive a concurrent iteration delete
  # between the aggregate scan and the per-goal fetch (read_model.ex).
  # ===========================================================================

  describe "L7: list_goals/0 survives a concurrent iteration delete" do
    setup :checkout_sandbox

    test "does not crash when the latest iteration is deleted mid-scan" do
      goal_ref = "l7-race-#{System.unique_integer([:positive])}"
      vector = PredicateVector.new(%{unit: PredicateResult.pass(%{exit: 0})})

      {:ok, _} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: 0,
          predicate_vector: vector
        })

      # Reproduce the TOCTOU: the instant the aggregate scan (the FIRST of
      # build_goal_summary/1's two queries) completes, delete the iteration —
      # before the subsequent per-goal get_iteration/2 fetch runs. Scoped to
      # THIS test's unique goal_ref, so it is a safe no-op if it ever fires
      # against another concurrently-running test's query (it won't, this file
      # is async: false, but the guard costs nothing).
      handler_id = "l7-race-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kazi, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata |> Map.get(:query) |> to_string() |> String.downcase()

          if String.contains?(query, "group by") do
            Repo.delete_all(from(i in ReadModel.Iteration, where: i.goal_ref == ^goal_ref))
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Must not raise; the deleted goal is simply absent from the summary.
      summaries = ReadModel.list_goals()
      refute Enum.any?(summaries, &(&1.goal_ref == goal_ref))
    end
  end

  # ===========================================================================
  # L8 — LeaseTable.forget must be keyed by holder identity, so an outgoing
  # holder's release cannot erase a fresh incoming holder's entry.
  # ===========================================================================

  describe "L8: LeaseTable.forget is holder-keyed" do
    defp lease(key, holder),
      do: %Lease{key: key, holder: holder, revision: 1, expires_at_ms: 30_000}

    test "forget is a no-op when the recorded holder no longer matches (a race with a new holder)" do
      name = :"l8_lease_table_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: name, start: {LeaseTable, :start_link, [[name: name]]}})

      # The race: partition A releases key K (agent-1); by the time its `forget`
      # runs, partition B has already `record`ed its own hold of K (agent-2).
      :ok = LeaseTable.record(lease("blast:lib/a.ex", "agent-1"), name)
      :ok = LeaseTable.record(lease("blast:lib/a.ex", "agent-2"), name)

      :ok = LeaseTable.forget(lease("blast:lib/a.ex", "agent-1"), name)

      assert [%Lease{key: "blast:lib/a.ex", holder: "agent-2"}] = LeaseTable.list(name)
    end

    test "forget still removes the entry when the holder matches (the normal release path)" do
      name = :"l8_lease_table_#{System.unique_integer([:positive])}"
      start_supervised!(%{id: name, start: {LeaseTable, :start_link, [[name: name]]}})

      :ok = LeaseTable.record(lease("blast:lib/a.ex", "agent-1"), name)
      :ok = LeaseTable.forget(lease("blast:lib/a.ex", "agent-1"), name)

      assert LeaseTable.list(name) == []
    end
  end

  # ===========================================================================
  # L9 — the per-run budget-spend Agent must be stopped even when run/2
  # returns {:error, _} (scheduler.ex).
  # ===========================================================================

  describe "L9: the budget-spend Agent is stopped even when run/2 errors" do
    test "run_goals/2 leaks no process on a coordinator start failure" do
      Process.flag(:trap_exit, true)
      :erlang.trace(self(), true, [:procs])

      source = StaticGraphSource.new(files: ["lib/a.ex"])
      goal = Goal.new("l9-error-path-#{System.unique_integer([:positive])}")
      bogus_supervisor = :"l9_nonexistent_supervisor_#{System.unique_integer([:positive])}"

      assert {:error, _reason} =
               Kazi.Scheduler.run_goals([goal],
                 workspace: "/ws",
                 graph_source: source,
                 supervisor: bogus_supervisor,
                 reconcile_timeout: 1_000,
                 budget: Budget.new(max_iterations: 10)
               )

      :erlang.trace(self(), false, [:procs])

      spawned = collect_spawned([])

      assert Enum.all?(spawned, &(not Process.alive?(&1))),
             "expected every process spawned during the failed run_goals/2 call to have exited " <>
               "(the budget-spend Agent must be stopped on the error path too)"
    end

    defp collect_spawned(acc) do
      receive do
        {:trace, _pid, :spawn, child, _mfa} -> collect_spawned([child | acc])
      after
        0 -> acc
      end
    end
  end

  # ===========================================================================
  # L10 — notify_iteration's reported converged? must agree with the actual
  # convergence decision (loop.ex). i795/#795 changed WHAT that decision is (a
  # quarantined predicate — status `:unknown` — no longer manufactures a false
  # `:converged`; see loop_test.exs), but the L10 invariant itself (the two
  # never disagree) still applies and is pinned below.
  # ===========================================================================

  defmodule L10FlipProvider do
    @moduledoc false
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.flip_pid

      n =
        Agent.get_and_update(pid, fn counts ->
          c = Map.get(counts, id, 0)
          {c, Map.put(counts, id, c + 1)}
        end)

      # Alternates fail/pass across re-runs WITHIN one observation — the T1.3
      # flake re-run policy classifies this as flaky and quarantines it.
      status = if rem(n, 2) == 0, do: :fail, else: :pass
      PredicateResult.new(status, %{eval: n})
    end
  end

  defmodule L10SolidProvider do
    @moduledoc false
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{}, _context), do: PredicateResult.pass(%{ok: true})
  end

  defmodule L10NoopHarness do
    @moduledoc false
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok", cost: %{tokens: 0}}}
  end

  defmodule L10NoopIntegrate do
    @moduledoc false
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule L10NoopDeploy do
    @moduledoc false
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  describe "L10: notify_iteration's converged? matches the real convergence decision" do
    test "a quarantined predicate keeps every iteration's converged? false, matching the (non-converged) terminal outcome" do
      {:ok, flip_pid} = L10FlipProvider.start_link(nil)
      test = self()

      goal =
        Goal.new("l10-quarantine-converge",
          predicates: [Predicate.new(:flaky, :tests), Predicate.new(:solid, :solid_tests)],
          metadata: %{flip_pid: flip_pid}
        )

      {:ok, loop} =
        Kazi.Loop.start_link(
          goal: goal,
          providers: %{tests: L10FlipProvider, solid_tests: L10SolidProvider},
          harness: L10NoopHarness,
          integrate: L10NoopIntegrate,
          deploy: L10NoopDeploy,
          workspace: "/fixture/ws",
          on_iteration: fn payload -> send(test, {:iteration, payload}) end,
          flake_max_retries: 2,
          reobserve_interval_ms: 5,
          stuck_iterations: 0
        )

      # i795/#795: a quarantined predicate (`:unknown`) never lets the run
      # report `:converged`. #820: it never rehabilitates here either (it keeps
      # alternating on every real re-poll), so with the vector blocked SOLELY by
      # quarantine and nothing dispatchable, the loop stops honestly `:stuck`
      # rather than idling forever.
      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
      refute result.outcome == :converged
      assert result.outcome == :stopped
      assert result.reason == :stuck

      snap = Kazi.Loop.snapshot(loop)
      assert :flaky in snap.quarantine

      converging_payload =
        receive do
          {:iteration, payload} -> payload
        after
          200 -> flunk("expected at least one on_iteration event")
        end

      # The L10 invariant: notify_iteration's converged? must agree with the
      # real convergence decision. Both now delegate to the very same
      # `all_satisfied?/1`, so they can never disagree.
      assert converging_payload.converged? ==
               PredicateVector.satisfied?(converging_payload.vector)

      assert converging_payload.converged? == false

      Kazi.Loop.stop(loop)
    end
  end

  # ===========================================================================
  # L11 — an unrecognized --context-store name must warn, not silently leave
  # the store off (cli.ex).
  # ===========================================================================

  describe "L11: an unknown --context-store warns instead of silently disabling" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "warns on stderr and names the offending value", %{tmp_dir: tmp_dir} do
      goal_file = Path.join(tmp_dir, "l11.toml")

      File.write!(goal_file, """
      id = "l11-ctx-store"
      name = "L11 unknown context store"

      [budget]
      max_iterations = 1

      [[predicate]]
      id = "ok"
      provider = "custom_script"
      cmd = "true"
      """)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Kazi.CLI.run(
              ["apply", goal_file, "--workspace", tmp_dir, "--context-store", "bogus-provider"],
              []
            )
          end)
        end)

      assert stderr =~ "warning: unknown --context-store"
      assert stderr =~ "bogus-provider"
    end
  end

  # ===========================================================================
  # L12 — enforcement_guard/1 must validate direction/baseline, not accept a
  # typo'd config verbatim (loader.ex).
  # ===========================================================================

  describe "L12: enforcement guard config is validated" do
    defp base_enforcement_goal(guard) do
      %{
        "id" => "l12-guard",
        "enforcement" => %{"guard" => [guard]},
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      }
    end

    test "a valid direction + numeric baseline loads" do
      guard = %{
        "id" => "cov",
        "metric" => %{},
        "direction" => "higher_better",
        "baseline" => 80.0
      }

      assert {:ok, %Goal{}} = Loader.from_map(base_enforcement_goal(guard))
    end

    test "an unknown direction is a load error" do
      guard = %{"id" => "cov", "direction" => "sideways_better"}
      assert {:error, reason} = Loader.from_map(base_enforcement_goal(guard))
      assert reason =~ "\"direction\""
    end

    test "a non-number, non-string baseline is a load error" do
      guard = %{"id" => "cov", "baseline" => true}
      assert {:error, reason} = Loader.from_map(base_enforcement_goal(guard))
      assert reason =~ "\"baseline\""
    end

    test "an empty-string baseline is a load error" do
      guard = %{"id" => "cov", "baseline" => ""}
      assert {:error, reason} = Loader.from_map(base_enforcement_goal(guard))
      assert reason =~ "\"baseline\""
    end
  end

  # ===========================================================================
  # L13 — serialize_action_params/1 must sanitize non-JSON-safe params the
  # same way evidence is sanitized, defensively (read_model.ex).
  # ===========================================================================

  describe "L13: serialize_action_params sanitizes non-JSON-safe params" do
    setup :checkout_sandbox

    test "a tuple value and an atom key in action.params round-trip JSON-safe" do
      goal_ref = "l13-#{System.unique_integer([:positive])}"

      action =
        Action.new(:dispatch_agent,
          params: %{failing: ["probe"], detail: {:cmd_unrunnable, "boom"}}
        )

      vector = PredicateVector.new(%{unit: PredicateResult.pass(%{exit: 0})})

      assert {:ok, _} =
               ReadModel.record_iteration(%{
                 goal_ref: goal_ref,
                 iteration_index: 0,
                 predicate_vector: vector,
                 action: action
               })

      assert %ReadModel.Iteration{action_params: params} = ReadModel.get_iteration(goal_ref, 0)

      # Keys are strings; the tuple value is rendered via inspect/1 (JSON-safe),
      # never stored verbatim (which would fail the :map cast, per the finding).
      assert %{"failing" => ["probe"], "detail" => detail} = params
      assert detail =~ "cmd_unrunnable"
      assert detail =~ "boom"
    end
  end
end
