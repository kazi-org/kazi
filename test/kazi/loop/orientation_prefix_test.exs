defmodule Kazi.Loop.OrientationPrefixTest do
  @moduledoc """
  T19.1 (ADR-0010 §3, realizing the unwired T4.3): the live `dispatch_prompt/2`
  carries the ranked blast-radius orientation pack as a STABLE, cacheable PREFIX
  ahead of the failing-evidence + working-set-digest body.

  These tests drive a real dispatch through `Kazi.Loop` (the orientation builder
  is fed a hermetic `Kazi.Context.StaticGraphSource` via `adapter_opts`, so no
  filesystem/network access) and capture the exact prompt the harness receives:

    * a workspace WITH a graph/repo-map injects the pack ahead of the evidence;
    * the prefix is byte-identical across iterations whose blast radius is
      unchanged (the cache-hit discipline T19.2 builds on);
    * the failing-evidence + working-set-digest sections are PRESERVED;
    * NO graph/repo-map ⇒ NO prefix (byte-identical to the pre-T19.1 prompt).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Context.StaticGraphSource

  # A code predicate provider scripted per id: pops the next status, holding the
  # last forever. Lets a test express "fail, fail, then pass" so the loop
  # dispatches twice (two iterations, same failing set ⇒ same blast radius)
  # before converging.
  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(script) when is_map(script), do: Agent.start_link(fn -> script end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.script_pid

      status =
        Agent.get_and_update(pid, fn script ->
          case Map.get(script, id, [:pass]) do
            [last] -> {last, %{script | id => [last]}}
            [next | rest] -> {next, %{script | id => rest}}
          end
        end)

      Kazi.PredicateResult.new(status, %{output: "boom in lib/widget.ex"})
    end
  end

  # Harness double: forwards every dispatch prompt to the collector pid so the
  # test can inspect the exact text `dispatch_prompt/2` produced, and reports a
  # touched working set so the SECOND dispatch carries a non-empty digest (the
  # body the prefix must sit AHEAD of).
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:dispatched, prompt})
      {:ok, %{output: "ok", cost: %{tokens: 1}, touched: ["lib/widget.ex"]}}
    end
  end

  # Trivial integrate/deploy doubles so the loop can reach convergence once the
  # scripted code predicate goes green (the loop requires both actions). They do
  # nothing the orientation tests assert on.
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

  @graph_source StaticGraphSource.new(
                  origin: :graph,
                  files: ["lib/widget.ex", "lib/other.ex"],
                  symbols: [{"render_widget/1", "lib/widget.ex", callers: ["page/0"]}],
                  test_sources: [{"test/widget_test.exs", source: "assert Widget.render(1)"}]
                )

  defp goal(script_pid) do
    Goal.new("orientation-prefix-test",
      predicates: [Predicate.new(:code, :tests)],
      metadata: %{script_pid: script_pid}
    )
  end

  # Start a loop that dispatches against a workspace, threading the hermetic graph
  # source (and any extra adapter opts) so the orientation prefix is built without
  # touching the filesystem.
  defp start_loop(opts) do
    {:ok, script_pid} = ScriptedProvider.start_link(Keyword.fetch!(opts, :script))

    adapter_opts =
      [collector: self()] ++ Keyword.get(opts, :adapter_opts, [])

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal(script_pid),
        providers: %{tests: ScriptedProvider},
        harness: RecordingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: Keyword.get(opts, :workspace, "/fixture/ws"),
        adapter_opts: adapter_opts,
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    {:ok, _result} = Kazi.Loop.await(loop, 5_000)
    :ok
  end

  # The leading "# Orientation …" prefix, isolated from the volatile body. The
  # body begins at the FIRST of the working-set digest ("# Working set") or the
  # failing-evidence ("goal=") marker — so cutting at whichever appears first
  # yields exactly the orientation prefix, independent of whether a digest is
  # present this iteration.
  defp prefix_of(prompt) do
    cut =
      ["# Working set", "goal="]
      |> Enum.map(&:binary.match(prompt, &1))
      |> Enum.reject(&(&1 == :nomatch))
      |> Enum.map(&elem(&1, 0))
      |> Enum.min()

    binary_part(prompt, 0, cut)
  end

  describe "with a graph/repo-map present" do
    test "injects the orientation pack as a PREFIX, ahead of the failing-evidence section" do
      :ok =
        start_loop(script: %{code: [:fail, :pass]}, adapter_opts: [graph_source: @graph_source])

      assert_received {:dispatched, prompt}

      # The pack content is present…
      assert prompt =~ "# Orientation"
      assert prompt =~ "lib/widget.ex"
      assert prompt =~ "render_widget/1"

      # …and it leads the prompt, AHEAD of the evidence body (the "goal=" line).
      orientation_at = :binary.match(prompt, "# Orientation") |> elem(0)
      evidence_at = :binary.match(prompt, "goal=orientation-prefix-test") |> elem(0)
      assert orientation_at < evidence_at
    end

    test "the prefix is byte-identical across iterations with an unchanged blast radius" do
      # Fail twice (same failing set ⇒ same blast radius) then pass: two dispatches.
      :ok =
        start_loop(
          script: %{code: [:fail, :fail, :pass]},
          adapter_opts: [graph_source: @graph_source]
        )

      assert_received {:dispatched, first}
      assert_received {:dispatched, second}

      # The volatile tail differs (the 2nd dispatch carries the working-set
      # digest from the 1st), but the stable orientation head is byte-identical —
      # the property T19.2's inner-harness prompt-cache hit relies on.
      assert prefix_of(first) =~ "# Orientation"
      assert prefix_of(first) == prefix_of(second)
    end

    test "preserves the failing-evidence and working-set-digest sections" do
      :ok =
        start_loop(
          script: %{code: [:fail, :fail, :pass]},
          adapter_opts: [graph_source: @graph_source]
        )

      assert_received {:dispatched, _first}
      assert_received {:dispatched, second}

      # Evidence section (the body the prefix sits ahead of) is still there.
      assert second =~ "goal=orientation-prefix-test fix failing predicates: code"
      assert second =~ "evidence:"

      # The working-set digest distilled from the 1st dispatch's touched set
      # (map memory) is carried into the 2nd dispatch — preserved, not replaced.
      assert second =~ "# Working set (prior iteration, map memory only)"
      assert second =~ "lib/widget.ex"

      # Ordering: orientation prefix, then working-set digest, then evidence.
      orientation_at = :binary.match(second, "# Orientation") |> elem(0)
      digest_at = :binary.match(second, "# Working set") |> elem(0)
      evidence_at = :binary.match(second, "goal=orientation-prefix-test") |> elem(0)
      assert orientation_at < digest_at
      assert digest_at < evidence_at
    end
  end

  describe "with NO graph/repo-map (empty orientation pack)" do
    # An injected source that surveys nothing — the no-graph / empty-repo-map case.
    @empty_source StaticGraphSource.new(
                    origin: :repo_map,
                    files: [],
                    symbols: [],
                    test_sources: []
                  )

    test "adds NO prefix — byte-identical to the pre-T19.1 evidence-only prompt" do
      :ok =
        start_loop(script: %{code: [:fail, :pass]}, adapter_opts: [graph_source: @empty_source])

      assert_received {:dispatched, prompt}

      refute prompt =~ "# Orientation"
      # The prompt begins exactly at the evidence body — no empty-prefix garbage.
      assert String.starts_with?(
               prompt,
               "goal=orientation-prefix-test fix failing predicates: code"
             )
    end
  end
end
