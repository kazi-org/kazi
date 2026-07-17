defmodule Kazi.Loop.StuckBundleTest do
  @moduledoc """
  T35.6: a stuck run surfaces a bounded `stuck_bundle` on the result (failing
  predicates + changed files + budget-fitted store snippets), so the ADR-0035
  escalation hands the higher rung the bundle, not the full transcript.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateResult}

  # Fails forever with a fixed evidence blob, so the same failing set persists and
  # the loop stops :stuck after the stuck window.
  defmodule StuckProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, context),
      do: PredicateResult.fail(%{id: id, output: context.goal.metadata.evidence})
  end

  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _ws, _opts), do: {:ok, %{output: "ok", cost: %{tokens: 1}}}
  end

  defmodule NoopAction do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{}, _ctx), do: {:ok, %{}}
  end

  # (issue #769) A harness whose tool calls were all DENIED: it exits cleanly and
  # reports usage — exactly what `claude -p` does against a workspace that has not
  # been through the interactive trust dialog (`is_error: false`, exit 0) — while
  # changing nothing. The `tool_input` is deliberately fat here to prove the bundle
  # keeps NAMES only and never the payload.
  defmodule DenyingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _ws, _opts) do
      {:ok,
       %{
         output: "I don't have permission to write that file yet.",
         cost: %{tokens: 1},
         permission_denials: [
           %{
             tool_name: "Write",
             tool_use_id: "toolu_1",
             tool_input: %{
               "file_path" => "/tmp/x.ex",
               "content" => String.duplicate("SECRET", 500)
             }
           },
           %{tool_name: "Bash", tool_use_id: "toolu_2", tool_input: %{"command" => "git commit"}},
           # A repeat of an already-denied tool across dispatches must not stack up.
           %{
             tool_name: "Write",
             tool_use_id: "toolu_3",
             tool_input: %{"file_path" => "/tmp/y.ex"}
           }
         ]
       }}
    end
  end

  test "a stuck run produces a bounded stuck_bundle naming the failing predicates" do
    goal =
      Goal.new("stuck-bundle-test",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{evidence: "expected 200 got 404\n" <> String.duplicate("trace line\n", 50)}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: StuckProvider},
        harness: RecordingHarness,
        integrate: NoopAction,
        deploy: NoopAction,
        adapter_opts: [],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        # stop :stuck after the same failing set persists across 2 observations.
        stuck_iterations: 2
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck

    bundle = result.stuck_bundle
    assert is_map(bundle)
    assert [%{"id" => "code", "failure" => failure}] = bundle["failing_predicates"]
    assert failure =~ "404"
    assert is_integer(bundle["bytes"]) and bundle["bytes"] > 0
    # No store configured → no snippets, but the bundle still carries the signal.
    assert bundle["snippets"] == []
  end

  # (issue #769) The bug this pins: a fully-denied dispatch is indistinguishable
  # from "the agent chose to change nothing" — exit 0, no edits, budget spent, and
  # the loop grinds to :stuck with the cause NOWHERE in its output. The profile
  # already parsed `permission_denials`; the loop used to drop them on the floor.
  test "a stuck run whose tool calls were DENIED names them in the bundle" do
    goal =
      Goal.new("denied-bundle-test",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{evidence: "expected 200 got 404"}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: StuckProvider},
        harness: DenyingHarness,
        integrate: NoopAction,
        deploy: NoopAction,
        adapter_opts: [],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 2
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.reason == :stuck

    bundle = result.stuck_bundle
    denials = bundle["permission_denials"]

    # The names are there, deduped across repeats and dispatches.
    assert "Write" in denials
    assert "Bash" in denials
    assert denials == Enum.uniq(denials)

    # NAMES ONLY: a denied Write's tool_input is the entire file content it meant to
    # write. It must never reach the bundle — byte budget and secret-leak risk.
    rendered = Kazi.Context.StuckBundle.render(bundle)
    refute rendered =~ "SECRET"
    refute inspect(bundle) =~ "SECRET"
    refute inspect(bundle) =~ "tool_use_id"

    # The render tells the escalated rung WHY nothing changed.
    assert rendered =~ "Denied tool calls"
    assert rendered =~ "permission_mode"
  end

  # An unaffected bundle's shape must be byte-for-byte unchanged: the key is absent,
  # not an empty list, so existing consumers see nothing new.
  test "a stuck run with no denials OMITS the permission_denials key" do
    goal =
      Goal.new("no-denial-bundle-test",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{evidence: "boom"}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: StuckProvider},
        harness: RecordingHarness,
        integrate: NoopAction,
        deploy: NoopAction,
        adapter_opts: [],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 2
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.reason == :stuck
    refute Map.has_key?(result.stuck_bundle, "permission_denials")
    refute Kazi.Context.StuckBundle.render(result.stuck_bundle) =~ "Denied tool calls"
  end

  test "a non-stuck terminal result carries NO stuck_bundle" do
    # A predicate that passes immediately → :converged, never stuck.
    goal =
      Goal.new("converges",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{evidence: "n/a"}
      )

    defmodule PassProvider do
      @behaviour Kazi.PredicateProvider
      @impl true
      def evaluate(%Predicate{id: id}, _ctx), do: PredicateResult.pass(%{id: id})
    end

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: PassProvider},
        harness: RecordingHarness,
        integrate: NoopAction,
        deploy: NoopAction,
        adapter_opts: [],
        reobserve_interval_ms: 5
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged
    refute Map.has_key?(result, :stuck_bundle)
  end
end
