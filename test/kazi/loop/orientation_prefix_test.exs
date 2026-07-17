defmodule Kazi.Loop.OrientationPrefixTest do
  @moduledoc """
  T19.1/T19.2/T19.3 (ADR-0010): the live `dispatch_prompt/2` front-loads its
  sections stable → volatile — orientation pack → work-item → working-set digest
  → failing evidence — so the WHOLE head up to the evidence is byte-identical
  across iterations whose blast radius + work-item are unchanged, and the evidence
  is bounded by the T4.8 cap.

  These tests drive a real dispatch through `Kazi.Loop` (the orientation builder
  is fed a hermetic `Kazi.Context.StaticGraphSource` via `adapter_opts`, so no
  filesystem/network access) and capture the exact prompt the harness receives:

    * a workspace WITH a graph/repo-map injects the pack ahead of the evidence;
    * the orientation prefix is byte-identical across iterations whose blast radius
      is unchanged (T19.1);
    * the STABLE prefix up to the evidence (orientation → work-item → digest) is
      byte-identical across iterations; only the trailing evidence moves (T19.2);
    * the section order is orientation → work-item → digest → evidence (T19.2);
    * evidence larger than the cap is truncated head+tail; small evidence is
      unchanged (T19.3, via `Kazi.Harness.Prompt.truncate_evidence/2`);
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

      # The failing-predicate evidence `dispatch_prompt/2` renders. Defaults to a
      # small marker; a test may inject a large `:evidence_output` via goal metadata
      # to exercise the T19.3 truncation cap.
      output = Map.get(context.goal.metadata, :evidence_output, "boom in lib/widget.ex")
      Kazi.PredicateResult.new(status, %{output: output})
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

  defp goal(script_pid, metadata, conventions) do
    Goal.new("orientation-prefix-test",
      predicates: [Predicate.new(:code, :tests)],
      conventions: conventions,
      metadata: Map.merge(%{script_pid: script_pid}, metadata)
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
        goal:
          goal(
            script_pid,
            Keyword.get(opts, :metadata, %{}),
            # T44.4: the process contract is ON by default; these orientation
            # tests pin ORIENTATION behavior, so a case asserting the body starts
            # at the work-item disables the (independent) contract via this opt.
            Keyword.get(opts, :conventions, Kazi.Goal.default_conventions())
          ),
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

  # The leading "# Orientation …" prefix, isolated from the volatile body. With the
  # T19.2 front-loaded order (orientation → work-item → digest → evidence), the body
  # begins at the work-item ("goal=") line — the first section AFTER the orientation
  # pack — so cutting there yields exactly the orientation prefix.
  defp prefix_of(prompt) do
    {cut, _} = :binary.match(prompt, "goal=")
    binary_part(prompt, 0, cut)
  end

  # The STABLE prefix up to the volatile evidence (T19.2): everything ahead of the
  # "evidence:" marker — orientation → work-item → digest. This is the head the
  # inner harness's prompt cache hits on; only the trailing evidence moves between
  # iterations whose blast radius + work-item are unchanged.
  defp stable_prefix_of(prompt) do
    {cut, _} = :binary.match(prompt, "evidence:")
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

      # T19.2 front-loaded order (stable → volatile):
      #   orientation → work-item ("goal=") → working-set digest → evidence.
      orientation_at = :binary.match(second, "# Orientation") |> elem(0)
      work_item_at = :binary.match(second, "goal=orientation-prefix-test") |> elem(0)
      digest_at = :binary.match(second, "# Working set") |> elem(0)
      evidence_at = :binary.match(second, "evidence:") |> elem(0)
      assert orientation_at < work_item_at
      assert work_item_at < digest_at
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
      # T44.4: disable the (orientation-independent) process contract so this
      # test still pins that NO orientation ⇒ the prompt begins at the work-item.
      :ok =
        start_loop(
          script: %{code: [:fail, :pass]},
          adapter_opts: [graph_source: @empty_source],
          conventions: %{process_contract: false, extra_rules: []}
        )

      assert_received {:dispatched, prompt}

      refute prompt =~ "# Orientation"
      # The prompt begins exactly at the work-item line — no empty-prefix garbage.
      assert String.starts_with?(
               prompt,
               "goal=orientation-prefix-test fix failing predicates: code"
             )
    end
  end

  describe "T19.4 no-prefix flag (benchmark arm B)" do
    test "orientation_prefix: false DISABLES the prefix even WITH a graph present" do
      # Arm B: a graph IS present (so the default would add a prefix), but the
      # additive `:orientation_prefix` opt is false — the pre-T19.1 behaviour.
      :ok =
        start_loop(
          script: %{code: [:fail, :pass]},
          adapter_opts: [graph_source: @graph_source, orientation_prefix: false],
          # T44.4: contract off so this pins ORIENTATION disabling alone.
          conventions: %{process_contract: false, extra_rules: []}
        )

      assert_received {:dispatched, prompt}

      refute prompt =~ "# Orientation"
      # The prompt begins exactly at the work-item line — the evidence-only body.
      assert String.starts_with?(
               prompt,
               "goal=orientation-prefix-test fix failing predicates: code"
             )
    end

    test "orientation_prefix: true (and the default) KEEPS the prefix (arm C)" do
      # Arm C / current default: the prefix is present, matching T19.1.
      :ok =
        start_loop(
          script: %{code: [:fail, :pass]},
          adapter_opts: [graph_source: @graph_source, orientation_prefix: true]
        )

      assert_received {:dispatched, explicit}
      assert explicit =~ "# Orientation"

      # And the DEFAULT (no opt) is byte-identical to the explicit `true` — the
      # current behaviour is unchanged by the additive flag.
      :ok =
        start_loop(script: %{code: [:fail, :pass]}, adapter_opts: [graph_source: @graph_source])

      assert_received {:dispatched, default}
      assert default =~ "# Orientation"
      assert prefix_of(default) == prefix_of(explicit)
    end
  end

  describe "T19.2 stable-prefix discipline (inner-harness cache hits)" do
    test "the stable head (orientation → work-item → digest) ends exactly at the volatile evidence" do
      :ok =
        start_loop(script: %{code: [:fail, :pass]}, adapter_opts: [graph_source: @graph_source])

      assert_received {:dispatched, prompt}

      # The stable head carries the orientation pack and the work item, and ends
      # precisely at the volatile "evidence:" marker — nothing volatile leaks into
      # the cacheable prefix.
      assert stable_prefix_of(prompt) =~ "# Orientation"
      assert stable_prefix_of(prompt) =~ "goal=orientation-prefix-test"
      refute stable_prefix_of(prompt) =~ "evidence:"
    end

    test "across two dispatches with unchanged state the stable prefix is byte-identical" do
      # Three failures then pass. The digest is recorded after the 1st dispatch and
      # is unchanged thereafter (the harness reports the SAME touched set each run),
      # so dispatches #2 and #3 share an identical blast radius, work-item AND
      # digest — their stable prefixes must be byte-for-byte equal.
      :ok =
        start_loop(
          script: %{code: [:fail, :fail, :fail, :pass]},
          adapter_opts: [graph_source: @graph_source]
        )

      assert_received {:dispatched, _first}
      assert_received {:dispatched, second}
      assert_received {:dispatched, third}

      # Identical stable head (orientation → work-item → digest) ⇒ inner-harness
      # prompt-cache hit across the dispatch.
      assert stable_prefix_of(second) =~ "# Orientation"
      assert stable_prefix_of(second) =~ "# Working set"
      assert stable_prefix_of(second) == stable_prefix_of(third)

      # And the trailing evidence is what differs (here identical too, but it is the
      # only section AFTER the stable boundary).
      assert second =~ "evidence:"
      assert third =~ "evidence:"
    end
  end

  describe "T19.3 evidence truncation on the live path (T4.8 cap)" do
    test "evidence larger than the cap is truncated head+tail (default 8 KiB)" do
      # 32 KiB of recognisable head/tail evidence, well over the 8 KiB default cap.
      big = String.duplicate("HEAD", 4_096) <> String.duplicate("TAIL", 4_096)

      :ok =
        start_loop(
          script: %{code: [:fail, :pass]},
          adapter_opts: [graph_source: @graph_source],
          metadata: %{evidence_output: big}
        )

      assert_received {:dispatched, prompt}

      # The cut is visible (the greppable marker) and both the head and the tail of
      # the original evidence survive the head+tail window.
      assert prompt =~ "…truncated…"
      assert prompt =~ "HEAD"
      assert prompt =~ "TAIL"

      # The whole 32 KiB did not pass through verbatim: the evidence section is
      # bounded near the ~8 KiB cap, not the full input length.
      refute prompt =~ String.duplicate("HEAD", 4_096)
    end

    test "small evidence is passed through unchanged (no truncation marker)" do
      :ok =
        start_loop(script: %{code: [:fail, :pass]}, adapter_opts: [graph_source: @graph_source])

      assert_received {:dispatched, prompt}

      # The default small marker survives verbatim and no cut is applied.
      assert prompt =~ "boom in lib/widget.ex"
      refute prompt =~ "…truncated…"
    end
  end
end
