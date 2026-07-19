defmodule Kazi.Loop.DemonstratorDispatchTest do
  # Loop routing (T49.7, ADR-0064 d3/d4): a failing scenario predicate blocked by
  # its pin routes to the DEMONSTRATOR through the same dispatch machinery, with no
  # decide/2 special case. The real Kazi.Providers.Scenario observes; a stub harness
  # mints the pin; the browser replay is stubbed via stub_playwright.sh.
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Scenario.Source

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  @feature """
  Feature: Greeting

    Scenario: A visitor sees the greeting
      Given the greeting page is open
      Then the greeting is shown
  """
  @scenario_name "A visitor sees the greeting"
  @url "https://example.test/greeting"

  # A stub harness that mints the pin the demonstrator was dispatched to write.
  defmodule MintingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, opts) do
      File.write!(Keyword.fetch!(opts, :pin_path), Keyword.fetch!(opts, :pin_json))
      {:ok, %{output: "minted", cost: %{tokens: 2}}}
    end
  end

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "noop", cost: %{tokens: 1}}}
  end

  # T49.9: a role-aware stub. The demonstrator prompt is fixed + controller-owned
  # (`Kazi.Scenario.Demonstrator.prompt/1`), so branching on it is how one harness
  # serves BOTH roles in a single run: mint the pin for the demonstrator, write the
  # fixer's marker otherwise.
  defmodule BothRolesHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(prompt, _workspace, opts) do
      if String.contains?(prompt, "Demonstrate a capability and pin it") do
        File.write!(Keyword.fetch!(opts, :pin_path), Keyword.fetch!(opts, :pin_json))
        {:ok, %{output: "minted", cost: %{tokens: 2}}}
      else
        File.write!(Keyword.fetch!(opts, :fix_marker), "fixed")
        {:ok, %{output: "fixed", cost: %{tokens: 2}}}
      end
    end
  end

  # Fails until the FIXER writes the marker. Gating on the fixer's side effect (not
  # an evaluation counter) is what makes the dispatch total deterministic: whichever
  # role the loop picks first, each role must run exactly once to converge.
  defmodule MarkerGatedProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{config: %{marker: marker}}, _context) do
      status = if File.exists?(marker), do: :pass, else: :fail
      Kazi.PredicateResult.new(status, %{output: "needs a fix in lib/widget.ex"})
    end
  end

  defmodule RecordingIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule RecordingDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_demo_loop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    spec = Path.join(dir, "greeting.feature")
    File.write!(spec, @feature)
    pin = Path.join(dir, "greeting.pin.json")

    {:ok, ws: dir, spec: spec, pin: pin}
  end

  defp scenario_sha do
    {:ok, scenario} = Source.extract(@feature, @scenario_name)
    Source.sha(scenario)
  end

  defp valid_pin_json(spec) do
    Jason.encode!(%{
      "pin_version" => 1,
      "spec" => spec,
      "scenario" => @scenario_name,
      "scenario_sha" => scenario_sha(),
      "surface" => "browser",
      "inputs" => %{},
      "trace" => %{
        "url" => @url,
        "steps" => [],
        "assertions" => [%{"type" => "visible", "selector" => "#greeting"}]
      },
      "map" => [%{"step" => "the greeting is shown", "steps" => [], "assertions" => [0]}]
    })
  end

  defp green_verdict do
    Jason.encode!(%{
      status: "pass",
      url: @url,
      assertions: [%{type: "visible", selector: "#greeting", ok: true}],
      screenshot: nil,
      error: nil
    })
  end

  defp scenario_goal(spec, pin) do
    predicate =
      Predicate.new("visitor-sees-greeting", :scenario,
        config: %{
          spec: spec,
          scenario: @scenario_name,
          pin: pin,
          surface: "browser",
          cmd: @stub,
          args: [],
          env: [{"STUB_JSON", green_verdict()}]
        }
      )

    Goal.new("demo-loop", predicates: [predicate], metadata: %{collector: self()})
  end

  defp start_loop(goal, harness, adapter_opts, providers \\ %{scenario: Kazi.Providers.Scenario}) do
    Kazi.Loop.start_link(
      goal: goal,
      providers: providers,
      harness: harness,
      integrate: RecordingIntegrate,
      deploy: RecordingDeploy,
      adapter_opts: adapter_opts,
      reobserve_interval_ms: 5,
      flake_max_retries: 0,
      stuck_iterations: 3
    )
  end

  test "an unpinned scenario dispatches the DEMONSTRATOR, not the fixer", %{spec: spec, pin: pin} do
    {:ok, loop} =
      start_loop(scenario_goal(spec, pin), MintingHarness,
        collector: self(),
        pin_path: pin,
        pin_json: valid_pin_json(spec)
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    # Routed to the demonstrator on the failing-predicate evidence — never the fixer.
    assert :dispatch_demonstrator in result.actions
    refute :dispatch_agent in result.actions

    # The minted pin validates + replays green, so the next observation passes.
    assert result.outcome == :converged
    assert File.exists?(pin)
  end

  test "a demonstrator whose harness mints no pin stays unpinned and never dispatches a fixer",
       %{spec: spec, pin: pin} do
    {:ok, loop} = start_loop(scenario_goal(spec, pin), NoopHarness, collector: self())

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    # The pin never gets written, so the scenario stays unpinned — the loop keeps
    # routing to the demonstrator (never the fixer) until it goes stuck.
    assert :dispatch_demonstrator in result.actions
    refute :dispatch_agent in result.actions
    refute File.exists?(pin)
  end

  test "a run with one fixer and one demonstrator dispatch counts BOTH toward dispatch_count",
       %{spec: spec, pin: pin, ws: ws} do
    marker = Path.join(ws, "fixed.marker")

    scenario =
      Predicate.new("visitor-sees-greeting", :scenario,
        config: %{
          spec: spec,
          scenario: @scenario_name,
          pin: pin,
          surface: "browser",
          cmd: @stub,
          args: [],
          env: [{"STUB_JSON", green_verdict()}]
        }
      )

    code = Predicate.new("widget-works", :marker_gated, config: %{marker: marker})

    goal =
      Goal.new("demo-loop-both-roles",
        predicates: [scenario, code],
        metadata: %{collector: self()}
      )

    {:ok, loop} =
      start_loop(
        goal,
        BothRolesHarness,
        [collector: self(), pin_path: pin, pin_json: valid_pin_json(spec), fix_marker: marker],
        %{scenario: Kazi.Providers.Scenario, marker_gated: MarkerGatedProvider}
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 10_000)
    assert result.outcome == :converged

    # Both roles ran, and they are DISTINCT action kinds — that distinction is what
    # `action_kind` persists per iteration row, and what the economy split reads.
    assert :dispatch_agent in result.actions
    assert :dispatch_demonstrator in result.actions

    # `result.dispatches` is verbatim what `Kazi.Runtime` writes to the read model as
    # `runs.dispatch_count`, so this pins the acc's "dispatch_count 2": the
    # demonstrator is NOT free — it counts against the dispatch budget like the fixer.
    assert result.dispatches == 2
  end
end
