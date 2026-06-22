defmodule Kazi.Slice1DogfoodTest do
  @moduledoc """
  Tier 2 — the SLICE-1 ACCEPTANCE DOGFOOD (T1.8, verifying UC-007).

  This is the trustworthiness analog of the Slice-0 dogfood (T0.11/T0.12): it
  demonstrates, end-to-end through the REAL `Kazi.Loop`, the exact scenario the
  whole slice exists for — **a naive fix that makes one predicate pass while
  REGRESSING another, and kazi catching it rather than declaring false success**
  (concept §5, ADR-0002, which rejects a single exit code precisely so this is
  detectable).

  ## The scenario (a genuine coupling, not a contrived flag)

  Two CODE predicates over a REAL temp workspace, evaluated by the REAL
  `Kazi.Providers.TestRunner` shelling out to `grep` (mirrors the Go fixture's
  not-ok→ok test shape used in the Slice-0 dogfood):

    * `pred_a` passes iff `a.txt` contains `ok`. It starts RED (`a.txt` = `broken`).
    * `pred_b` passes iff `b.txt` contains `ok`. It starts GREEN (`b.txt` = `ok`).

  The "naive fix" is a REAL harness binary (the `Kazi.Harness.ClaudeAdapter`
  `:command` seam, exactly as the Slice-0 full-loop test points it at a stub):
  it fixes `pred_a` (writes `ok` into `a.txt`) but, because the two predicates are
  COUPLED, it breaks `pred_b` as a side effect (writes `broken` into `b.txt`).
  Fixing A regresses B. This is the canonical "a fix for predicate A breaks
  predicate B" (concept §5) — observed through the real provider over a real
  mutated workspace, not faked with a status script.

  The harness is dumb and repeats the same coupled edit every dispatch, so once
  B is red it stays red: the failing set settles on `{pred_b}` and never empties.

  ## What this proves (the D1 acceptance)

    1. kazi DETECTS the regression: the regression detector flags `pred_b`
       green→red and attributes it to the agent dispatch that made the coupled
       edit — visible in `snapshot/1` AND read back from the persisted read-model.
    2. kazi does NOT falsely converge: the objective-termination guard (T0.8)
       holds — the vector is never all-pass because B is now failing, so
       `:converged` is never reached.
    3. kazi ESCALATES rather than spinning forever: the same non-empty failing
       set `{pred_b}` persists across the stuck window, the human-escalation hook
       fires once, and the loop stops `:stopped`/`:stuck`. The terminal outcome +
       reason are visible in `snapshot/1` and the persisted read-model.

  It substitutes nothing in `lib/`: the only test-only doubles are the
  Noop integrate/deploy actions (never reached — the loop never gets code-green)
  and a recording escalation/persistence callback. Hermetic: its own SQLite
  Sandbox connection, a real local harness binary, a real temp workspace — no Go,
  no network, no GitHub, no cloud.
  """
  # Real System.cmd (grep + the harness binary) + the shared SQLite Sandbox
  # connection: serial.
  use ExUnit.Case, async: false

  alias Kazi.{Goal, Loop, Predicate, PredicateVector, ReadModel, Repo, Scope}

  @moduletag :tmp_dir

  @goal_id "slice1-dogfood-t18"

  setup do
    # The loop's persistence seam (`on_iteration`) writes the read-model on the
    # loop's OWN process; share this checked-out Sandbox connection so the loop's
    # writes land in the transaction the test reads from (mirrors FullLoopTest).
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # Test-only doubles. The zero-stub policy is for lib/; these are test doubles the
  # loop's behaviours allow. integrate/deploy are NEVER reached (the code predicate
  # never goes green), but the loop requires the seams to be present.
  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  describe "naive fix regresses a coupled predicate (UC-007, the Slice-1 D1 dogfood)" do
    test "kazi detects the regression, never falsely converges, and escalates",
         %{tmp_dir: tmp_dir} do
      # --- ARRANGE: a real workspace with two COUPLED code predicates -----------
      #
      # a.txt starts "broken" (pred_a RED); b.txt starts "ok" (pred_b GREEN).
      workspace = Path.join(tmp_dir, "work")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "a.txt"), "broken\n")
      File.write!(Path.join(workspace, "b.txt"), "ok\n")

      # The "naive fix" harness: a REAL executable the ClaudeAdapter shells out to
      # (cd: workspace). It fixes pred_a (a.txt → ok) but, because the predicates
      # are coupled, BREAKS pred_b (b.txt → broken). This is the regression-causing
      # change — a genuine coupling observed through the real provider, not a flag.
      naive_fix = write_naive_fix_harness(tmp_dir)

      # Record escalations and persist iterations to the read-model exactly as the
      # runtime does (so the read-back assertions use the real persistence path).
      test_pid = self()

      goal =
        Goal.new(@goal_id,
          predicates: [
            # REAL test-runner predicates: grep genuinely fails until the file
            # contains exactly `ok` (the not-ok→ok shape of the Slice-0 fixture).
            Predicate.new(:pred_a, :tests,
              config: %{cmd: "sh", args: ["-c", "grep -q '^ok$' a.txt"]}
            ),
            Predicate.new(:pred_b, :tests,
              config: %{cmd: "sh", args: ["-c", "grep -q '^ok$' b.txt"]}
            )
          ],
          scope: Scope.new(workspace: workspace)
        )

      # --- ACT: drive the REAL loop to a terminal state -------------------------
      #
      # Real TestRunner provider, real ClaudeAdapter harness (pointed at the naive
      # fix binary), Noop integrate/deploy (never reached). Stuck window 3 so the
      # persistent {pred_b} failing set escalates; a small iteration budget is a
      # backstop so the test can never hang if escalation regressed.
      {:ok, loop} =
        Loop.start_link(
          goal: goal,
          providers: %{tests: Kazi.Providers.TestRunner},
          harness: Kazi.Harness.ClaudeAdapter,
          integrate: NoopIntegrate,
          deploy: NoopDeploy,
          workspace: workspace,
          adapter_opts: [command: naive_fix],
          # Poll fast so the dogfood does not wait on the production interval.
          reobserve_interval_ms: 5,
          # Detection + escalation are the point of the dogfood: stuck ON.
          stuck_iterations: 3,
          # Flake OFF: the failures here are real and deterministic, not flakes —
          # re-running the (deterministic) grep would only slow the dogfood.
          flake_max_retries: 0,
          # A generous backstop so the loop cannot spin forever even if escalation
          # regressed; the stuck window (3) trips well before this.
          budget: Kazi.Budget.new(max_iterations: 50),
          on_escalation: fn ctx -> send(test_pid, {:escalation, ctx}) end,
          on_iteration: persist_fn(@goal_id)
        )

      assert {:ok, result} = Loop.await(loop, 15_000)

      # --- ASSERT 1: kazi ESCALATED (did not spin forever) ----------------------
      #
      # The naive fix keeps regressing pred_b, so the failing set settles on
      # {pred_b} and never empties. The stuck detector fires on the persistent set
      # and the loop hands off to a human rather than burning the budget.
      assert result.outcome == :stopped,
             "the dogfood loop did not stop cleanly: #{inspect(result)}"

      assert result.reason == :stuck,
             "expected escalation via the stuck detector (reason :stuck), got " <>
               "#{inspect(result.reason)} — the loop must escalate the persistent " <>
               "regression, not burn the budget backstop"

      # The human-escalation hook fired exactly once, on the persistent set {pred_b}.
      assert_receive {:escalation, ctx}, 1_000
      assert ctx.failing == MapSet.new([:pred_b])
      refute_receive {:escalation, _}, 100

      # --- ASSERT 2: kazi did NOT falsely converge (T0.8 guard held) ------------
      #
      # The headline anti-success assertion: at NO point was the whole vector
      # all-pass, because the naive fix made pred_b fail the moment it made pred_a
      # pass. `:converged` requires the ENTIRE vector to hold (T0.8); a coupled
      # regression blocks it exactly as a first-time failure would.
      refute result.outcome == :converged
      final_vector = result.vector

      refute PredicateVector.satisfied?(final_vector),
             "the loop reported a satisfied vector despite the live regression on pred_b"

      # The real workspace confirms the coupling actually happened: the naive fix
      # made a.txt ok (pred_a green) AND broke b.txt (pred_b red).
      assert File.read!(Path.join(workspace, "a.txt")) |> String.trim() == "ok"
      assert File.read!(Path.join(workspace, "b.txt")) |> String.trim() == "broken"

      # --- ASSERT 3: kazi DETECTED the regression (snapshot/1) ------------------
      #
      # The regression detector flagged pred_b green→red and ATTRIBUTED it to the
      # agent dispatch whose coupled edit caused it. Visible in snapshot/1.
      snap = Loop.snapshot(loop)

      pred_b_flag =
        Enum.find(snap.regressions, fn flag -> flag.predicate_id == :pred_b end)

      assert pred_b_flag,
             "the green→red regression on pred_b was never flagged; snapshot " <>
               "regressions=#{inspect(snap.regressions)}"

      assert pred_b_flag.status == :fail
      # pred_b was green before, red after: green_iteration precedes red_iteration.
      assert pred_b_flag.green_iteration < pred_b_flag.red_iteration

      # Attributed to the agent dispatch made in the green→red window: a
      # :dispatch_agent whose failing work-list named pred_a (the naive fix the
      # loop sent to fix A, which broke B).
      assert %Kazi.Action{kind: :dispatch_agent} = pred_b_flag.attributed_dispatch
      assert :pred_a in pred_b_flag.attributed_dispatch.params.failing

      # The terminal stuck failing set is visible in snapshot/1 too.
      assert snap.stuck_failing == [:pred_b]
      assert snap.state == :stopped

      Loop.stop(loop)

      # --- ASSERT 4: the regression + terminal are READ BACK from the read-model -
      #
      # Detection is not enough to be trustworthy unless it is durable: the flag
      # the running loop produced must be queryable from the persisted read-model
      # (string-keyed on-disk form), not only from the in-memory snapshot.
      assert wait_until(fn -> ReadModel.regressions(@goal_id) != [] end, 2_000),
             "the regression was never persisted to the read-model"

      persisted_flags =
        ReadModel.regressions(@goal_id)
        |> Enum.flat_map(fn {_idx, flags} -> flags end)

      pred_b_persisted =
        Enum.find(persisted_flags, fn f -> f["predicate_id"] == "pred_b" end)

      assert pred_b_persisted,
             "pred_b regression not found in the persisted read-model: " <>
               inspect(persisted_flags)

      assert pred_b_persisted["status"] == "fail"

      # The iteration history was projected in order, and NO iteration is marked
      # converged (the loop never declared success).
      iterations = ReadModel.list_iterations(@goal_id)
      assert iterations != []

      refute Enum.any?(iterations, & &1.converged),
             "an iteration was persisted as converged despite the regression — the " <>
               "objective-termination guard (T0.8) regressed to 'code green is good enough'"

      # The persisted history witnesses BOTH halves of the coupling: an iteration
      # where pred_a is green AND pred_b is red (the moment the naive fix flipped
      # A green and B red). This is the regression made durable.
      coupled =
        Enum.any?(iterations, fn it ->
          v = ReadModel.to_predicate_vector(it)
          pass?(v, "pred_a") and not pass?(v, "pred_b")
        end)

      assert coupled,
             "no persisted iteration shows pred_a :pass while pred_b :fail — the " <>
               "coupled regression was not durably observed"

      # And the FIRST observation is the honest starting point: pred_a red (real
      # outstanding work), pred_b green (not yet regressed). The loop did not
      # mistake the initial state for either success or a regression.
      first = List.first(iterations)
      first_vector = ReadModel.to_predicate_vector(first)
      refute pass?(first_vector, "pred_a")
      assert pass?(first_vector, "pred_b")
    end
  end

  # --- helpers ----------------------------------------------------------------

  # The naive-fix harness: a REAL executable run with cd: workspace. It makes
  # pred_a pass (a.txt → ok) but, because pred_a and pred_b are coupled, BREAKS
  # pred_b (b.txt → broken). Idempotent (every dispatch makes the same edit), so
  # once B is red it stays red — the persistent failing set the loop escalates.
  defp write_naive_fix_harness(tmp_dir) do
    path = Path.join(tmp_dir, "naive_fix.sh")

    File.write!(path, """
    #!/bin/sh
    # The agent "fixes" pred_a...
    echo "ok" > a.txt
    # ...but the same change breaks the coupled pred_b (the naive regression).
    echo "broken" > b.txt
    echo "naive fix ran in $(pwd)"
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Project each iteration into the read-model exactly as Kazi.Runtime does, so
  # the read-back assertions exercise the real persistence path (including the
  # regression flags carried on the payload).
  defp persist_fn(goal_ref) do
    fn payload ->
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: payload.iteration,
        predicate_vector: payload.vector,
        converged: payload.converged?,
        regressions: Map.get(payload, :regressions, [])
      })

      :ok
    end
  end

  # A predicate result is "pass" iff its status is :pass; a nil (absent) counts as
  # not-pass. Tolerates the string-keyed on-disk vector.
  defp pass?(%PredicateVector{} = vector, id) do
    case PredicateVector.get(vector, id) do
      nil -> false
      %{status: status} -> status == :pass
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
