defmodule Kazi.Goal.GherkinSireFixtureTest do
  @moduledoc """
  T62.3 (ADR-0071): the LIVE acceptance fixture. `storage-store.feature` is the
  executable storage-port contract from the Sire project (sire.run); this suite
  proves it reconciles NATIVELY through the `gherkin` runtime provider —
  per-scenario verdicts, and a deliberately-broken scenario reds ONLY its own
  sub-predicate.

  CI ingests a CAPTURED real godog `--format=cucumber` run (the committed
  `storage-store.cucumber.json`, replayed by `storage-store-replay.sh`), so the
  proof stays green without a Go toolchain. The genuinely-live godog run (over
  Sire's real SQLite store) is recorded, with observed output, in
  `docs/devlog.md` — this test pins what CI can keep.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader
  alias Kazi.Providers.Gherkin

  @fixture_dir Path.expand("../../../priv/examples/gherkin", __DIR__)
  @feature Path.join(@fixture_dir, "storage-store.feature")

  # The four Scenarios of storage-store.feature, matched VERBATIM (edge case 3:
  # godog's cucumber-format scenario names equal the .feature text exactly).
  @scenarios [
    "a conflicting transaction rolls back",
    "values round-trip through a committed transaction",
    "migrations apply up and roll back down",
    "a dirty migration state blocks further migration"
  ]

  defp load(runner_args) do
    {:ok, goal} =
      Loader.from_map(%{
        "id" => "sire-storage-store",
        "name" => "sire-storage-store",
        "predicate" => [
          %{
            "provider" => "gherkin",
            "feature" => @feature,
            "verdict_format" => "cucumber_json",
            "runner_cmd" => "bash",
            "runner_args" => runner_args
          }
        ]
      })

    goal
  end

  defp verdicts(goal) do
    ctx = %{workspace: @fixture_dir, iteration: 1}

    for pred <- goal.predicates, into: %{} do
      {pred.config[:scenario], Gherkin.evaluate(pred, ctx).status}
    end
  end

  test "expands to one sub-predicate per Scenario, matched verbatim" do
    goal = load(["storage-store-replay.sh"])
    assert length(goal.predicates) == 4
    assert Enum.all?(goal.predicates, &(&1.kind == :gherkin))
    assert MapSet.new(Enum.map(goal.predicates, & &1.config[:scenario])) == MapSet.new(@scenarios)
  end

  test "a real captured godog run reconciles every scenario to pass" do
    verdicts = verdicts(load(["storage-store-replay.sh"]))

    for scenario <- @scenarios do
      assert verdicts[scenario] == :pass, "expected #{inspect(scenario)} to pass"
    end
  end

  test "a broken scenario reds ONLY its own sub-predicate" do
    verdicts = verdicts(load(["storage-store-broken-replay.sh"]))

    broken = "a conflicting transaction rolls back"
    assert verdicts[broken] == :fail

    for scenario <- @scenarios, scenario != broken do
      assert verdicts[scenario] == :pass, "expected #{inspect(scenario)} to stay green"
    end
  end
end
