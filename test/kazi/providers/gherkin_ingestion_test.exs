defmodule Kazi.Providers.GherkinIngestionTest do
  @moduledoc """
  T62.2 (ADR-0071 decisions 2–4): the runtime half of the `gherkin` provider —
  the caller-supplied runner runs ONCE per feature (memoized across the sibling
  scenario-sub-predicates from T62.1's expansion), its cucumber-json / scenario_map
  report is parsed once, and each sub-predicate reads its own verdict by scenario
  identity. A scenario absent from the report is honest `:unknown` (never `:fail`);
  a runner that cannot be observed makes every sibling `:unknown` with its captured
  output as evidence.
  """
  use ExUnit.Case, async: true

  alias Kazi.Predicate
  alias Kazi.Providers.Gherkin

  # A stub runner (bash script) that (1) records ONE invocation by appending a byte
  # to a counter file, then (2) prints `report` to stdout. Returns the script path
  # + the counter path, so a test can pin the memoized "exactly one run" contract.
  defp stub_runner(report, opts \\ []) do
    exit_code = Keyword.get(opts, :exit, 0)
    to_stderr? = Keyword.get(opts, :to_stderr, false)
    counter = tmp_path("counter")

    stream = if to_stderr?, do: ">&2", else: ""

    body = """
    #!/usr/bin/env bash
    printf 'x' >> #{counter}
    cat <<'KAZI_EOF' #{stream}
    #{report}
    KAZI_EOF
    exit #{exit_code}
    """

    path = tmp_path("runner.sh")
    File.write!(path, body)
    File.chmod!(path, 0o755)

    on_exit(fn ->
      File.rm(path)
      File.rm(counter)
    end)

    {path, counter}
  end

  defp tmp_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "kazi-gherkin-#{System.unique_integer([:positive])}-#{suffix}"
    )
  end

  defp run_count(counter),
    do: if(File.exists?(counter), do: byte_size(File.read!(counter)), else: 0)

  # A :gherkin sub-predicate as the loader's expansion would build it.
  defp pred(id, scenario, config) do
    Predicate.new(id, :gherkin, config: Map.merge(%{scenario: scenario}, config))
  end

  defp cucumber_json(scenarios) do
    features = [
      %{
        "name" => "Storage Store",
        "elements" =>
          Enum.map(scenarios, fn {name, verdict} ->
            status = if verdict == :pass, do: "passed", else: "failed"

            %{
              "name" => name,
              "type" => "scenario",
              "steps" => [%{"result" => %{"status" => status}}]
            }
          end)
      }
    ]

    Jason.encode!(features)
  end

  describe "memoization: one runner run per feature, shared across siblings" do
    test "N sibling sub-predicates trigger exactly ONE runner execution" do
      report = cucumber_json([{"A record is written", :pass}, {"A record is deleted", :fail}])
      {runner, counter} = stub_runner(report)

      shared = %{
        feature: "storage-store.feature",
        runner_cmd: runner,
        verdict_format: "cucumber_json"
      }

      context = %{workspace: System.tmp_dir!(), iteration: 0}

      p1 = pred("s__written", "A record is written", shared)
      p2 = pred("s__deleted", "A record is deleted", shared)

      # Evaluate both siblings in ONE pass (same process, same iteration).
      r1 = Gherkin.evaluate(p1, context)
      r2 = Gherkin.evaluate(p2, context)

      assert r1.status == :pass
      assert r2.status == :fail
      # Memoization pinned: two siblings, ONE run — not two.
      assert run_count(counter) == 1
    end

    test "a NEW reconcile pass (new iteration) re-runs the runner" do
      report = cucumber_json([{"A record is written", :pass}])
      {runner, counter} = stub_runner(report)

      shared = %{feature: "f.feature", runner_cmd: runner, verdict_format: "cucumber_json"}
      p = pred("s__written", "A record is written", shared)

      assert Gherkin.evaluate(p, %{workspace: System.tmp_dir!(), iteration: 0}).status == :pass
      assert Gherkin.evaluate(p, %{workspace: System.tmp_dir!(), iteration: 1}).status == :pass

      # One run per pass: the per-pass memo is keyed on the iteration.
      assert run_count(counter) == 2
    end
  end

  describe "verdict by scenario identity" do
    test "a passing scenario reads :pass, a failing scenario reads :fail" do
      report = cucumber_json([{"green", :pass}, {"red", :fail}])
      {runner, _} = stub_runner(report)
      shared = %{feature: "f.feature", runner_cmd: runner, verdict_format: "cucumber_json"}
      context = %{workspace: System.tmp_dir!(), iteration: 0}

      assert Gherkin.evaluate(pred("f__green", "green", shared), context).status == :pass
      assert Gherkin.evaluate(pred("f__red", "red", shared), context).status == :fail
    end

    test "a scenario present in the .feature but ABSENT from the report is :unknown, never :fail" do
      report = cucumber_json([{"present", :pass}])
      {runner, _} = stub_runner(report)
      shared = %{feature: "f.feature", runner_cmd: runner, verdict_format: "cucumber_json"}
      context = %{workspace: System.tmp_dir!(), iteration: 0}

      result = Gherkin.evaluate(pred("f__absent", "not in report", shared), context)

      assert result.status == :unknown
      assert result.evidence.reason == :scenario_absent_from_report
      assert "present" in result.evidence.available_scenarios
    end
  end

  describe "runner failure -> every sibling :unknown with output as evidence" do
    test "a runner that cannot spawn makes the sub-predicate :unknown with the error" do
      shared = %{
        feature: "f.feature",
        runner_cmd: "/no/such/kazi-gherkin-missing-runner",
        verdict_format: "cucumber_json"
      }

      result =
        Gherkin.evaluate(
          pred("f__s", "S", shared),
          %{workspace: System.tmp_dir!(), iteration: 0}
        )

      assert result.status == :unknown
      assert match?({:runner_unrunnable, _}, result.evidence.reason)
    end

    test "a runner that emits no parseable report -> :unknown with its stderr captured" do
      # Empty stdout + a diagnostic on stderr, nonzero exit: no report to parse.
      {runner, _} = stub_runner("boom: runner blew up", exit: 3, to_stderr: true)
      shared = %{feature: "f.feature", runner_cmd: runner, verdict_format: "cucumber_json"}

      result =
        Gherkin.evaluate(
          pred("f__s", "S", shared),
          %{workspace: System.tmp_dir!(), iteration: 0}
        )

      assert result.status == :unknown
      assert result.evidence.reason == :invalid_cucumber_json
      # The merged stream (its stderr) is captured as evidence.
      assert result.evidence.output =~ "boom: runner blew up"
    end
  end

  describe "a nonzero exit is NOT a failure to observe" do
    test "a runner exiting nonzero (a scenario failed) still ingests its report" do
      report = cucumber_json([{"ok", :pass}, {"broken", :fail}])
      # godog exits 1 when a scenario fails — the report is still authoritative.
      {runner, _} = stub_runner(report, exit: 1)
      shared = %{feature: "f.feature", runner_cmd: runner, verdict_format: "cucumber_json"}
      context = %{workspace: System.tmp_dir!(), iteration: 0}

      assert Gherkin.evaluate(pred("f__ok", "ok", shared), context).status == :pass
      assert Gherkin.evaluate(pred("f__broken", "broken", shared), context).status == :fail
    end
  end

  describe "verdict_format: scenario_map" do
    test "reads a flat {scenario => pass|fail} object" do
      report = Jason.encode!(%{"writes" => "pass", "deletes" => "fail"})
      {runner, counter} = stub_runner(report)
      shared = %{feature: "f.feature", runner_cmd: runner, verdict_format: "scenario_map"}
      context = %{workspace: System.tmp_dir!(), iteration: 0}

      assert Gherkin.evaluate(pred("f__writes", "writes", shared), context).status == :pass
      assert Gherkin.evaluate(pred("f__deletes", "deletes", shared), context).status == :fail
      assert run_count(counter) == 1
    end

    test "a scenario missing from a scenario_map is :unknown, never :fail" do
      report = Jason.encode!(%{"writes" => "pass"})
      {runner, _} = stub_runner(report)
      shared = %{feature: "f.feature", runner_cmd: runner, verdict_format: "scenario_map"}

      result =
        Gherkin.evaluate(
          pred("f__gone", "gone", shared),
          %{workspace: System.tmp_dir!(), iteration: 0}
        )

      assert result.status == :unknown
    end
  end

  describe "report source: report_path vs stdout" do
    test "reads the report from report_path when set (ignoring stdout)" do
      report = cucumber_json([{"from-file", :pass}])
      report_path = tmp_path("cucumber.json")
      File.write!(report_path, report)
      on_exit(fn -> File.rm(report_path) end)

      # The runner prints noise to stdout; the verdict must come from the file.
      {runner, counter} = stub_runner("not json — just a log line")

      shared = %{
        feature: "f.feature",
        runner_cmd: runner,
        verdict_format: "cucumber_json",
        report_path: report_path
      }

      result =
        Gherkin.evaluate(
          pred("f__file", "from-file", shared),
          %{workspace: System.tmp_dir!(), iteration: 0}
        )

      assert result.status == :pass
      assert run_count(counter) == 1
    end

    test "a missing report_path file -> :unknown (cannot observe), never :fail" do
      {runner, _} = stub_runner(cucumber_json([{"s", :pass}]))

      shared = %{
        feature: "f.feature",
        runner_cmd: runner,
        verdict_format: "cucumber_json",
        report_path: "/no/such/kazi-gherkin-missing-report.json"
      }

      result =
        Gherkin.evaluate(
          pred("f__s", "s", shared),
          %{workspace: System.tmp_dir!(), iteration: 0}
        )

      assert result.status == :unknown
      assert match?({:report_path_unreadable, _, _}, result.evidence.reason)
    end
  end

  describe "Scenario Outline rows: example-substituted name matching" do
    test "an outline row matches its example-substituted name in the report" do
      # The runner substitutes the row value into the reported scenario name.
      report = cucumber_json([{"Payment declined for expired", :pass}])
      {runner, _} = stub_runner(report)

      shared = %{
        feature: "f.feature",
        runner_cmd: runner,
        verdict_format: "cucumber_json",
        row_key: "expired",
        example: %{"card" => "expired"}
      }

      result =
        Gherkin.evaluate(
          pred("f__declined__expired", "Payment declined for <card>", shared),
          %{workspace: System.tmp_dir!(), iteration: 0}
        )

      assert result.status == :pass
    end
  end
end
