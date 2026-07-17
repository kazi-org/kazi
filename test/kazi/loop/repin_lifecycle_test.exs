defmodule Kazi.Loop.RepinLifecycleTest do
  # Loop-level repin lifecycle + capability_unreachable (T49.8, ADR-0064 d4).
  # Routing rides on the failing scenario's pin_state (a lightweight provider
  # double supplies it); the capability_unreachable termination uses the REAL
  # Scenario provider + a no-op harness so two demonstrations genuinely fail.
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateResult}

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  @feature """
  Feature: Greeting

    Scenario: A visitor sees the greeting
      Given the greeting page is open
      Then the greeting is shown
  """
  @scenario_name "A visitor sees the greeting"

  # Supplies a canned pin_state for the failing scenario, so the loop's routing
  # (demonstrator vs fixer) can be exercised without a real red replay.
  defmodule PinStateDouble do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, context) do
      PredicateResult.fail(%{
        id: id,
        pin_state: context.goal.metadata.pin_state,
        pin_path: "docs/specs/pins/x.pin.json",
        scenario_steps: [],
        reasons: []
      })
    end
  end

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "noop", cost: %{tokens: 1}}}
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

  defp start_loop(goal, providers, opts) do
    Kazi.Loop.start_link(
      [
        goal: goal,
        providers: providers,
        harness: NoopHarness,
        integrate: RecordingIntegrate,
        deploy: RecordingDeploy,
        adapter_opts: [],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 4
      ]
      |> Keyword.merge(opts)
    )
  end

  defp double_goal(pin_state) do
    Goal.new("repin-route",
      predicates: [
        Predicate.new("cap", :scenario, config: %{spec: "x", scenario: @scenario_name})
      ],
      metadata: %{pin_state: pin_state}
    )
  end

  test "a {:stale, :code_drift} scenario routes to the DEMONSTRATOR" do
    {:ok, loop} = start_loop(double_goal({:stale, :code_drift}), %{scenario: PinStateDouble}, [])
    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert :dispatch_demonstrator in result.actions
    refute :dispatch_agent in result.actions
  end

  test "a :pinned scenario whose replay is red routes to the FIXER (a regression, not a repin)" do
    {:ok, loop} = start_loop(double_goal(:pinned), %{scenario: PinStateDouble}, [])
    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert :dispatch_agent in result.actions
    refute :dispatch_demonstrator in result.actions
  end

  test "a :stale_manual scenario is never auto-demonstrated (repin = manual is operator work)" do
    {:ok, loop} = start_loop(double_goal(:stale_manual), %{scenario: PinStateDouble}, [])
    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    refute :dispatch_demonstrator in result.actions
  end

  # --- capability_unreachable: two real failed demonstrations, no code change ---

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_capunreach_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    spec = Path.join(dir, "greeting.feature")
    File.write!(spec, @feature)
    {:ok, ws: dir, spec: spec}
  end

  test "two consecutive failed demonstrations terminate :stuck with capability_unreachable (not over_budget)",
       %{ws: ws, spec: spec} do
    pin = Path.join(ws, "greeting.pin.json")

    goal =
      Goal.new("cap-unreach",
        predicates: [
          Predicate.new("cap", :scenario,
            config: %{
              spec: spec,
              scenario: @scenario_name,
              pin: pin,
              surface: "browser",
              cmd: @stub,
              args: []
            }
          )
        ],
        metadata: %{}
      )

    # The wedge fires at the 2nd failed demonstration (before any budget tick), so
    # capability_unreachable — not over_budget — is the cause.
    {:ok, loop} = start_loop(goal, %{scenario: Kazi.Providers.Scenario}, [])

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :stopped
    assert result.reason == :stuck
    assert result.cause.class == :capability_unreachable
    assert result.cause.ids == ["cap"]
    # It stalled on the demonstrator, never minted a pin, never dispatched a fixer.
    assert :dispatch_demonstrator in result.actions
    refute :dispatch_agent in result.actions
    refute File.exists?(pin)
  end
end
