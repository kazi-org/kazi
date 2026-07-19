defmodule Kazi.Providers.MutationTest do
  # Tier 2: real boundary. These run a command that emits a RECORDED mutation-tool
  # JSON report and assert the resulting PredicateResult, proving the :mutation
  # provider reads a 0-1 score from the PARSED output, gates it on a threshold
  # (never 100%), and surfaces surviving mutants — no live mutation run needed
  # (T32.8, ADR-0043).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Mutation

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_mutation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp evaluate(config, ws),
    do: Mutation.evaluate(Predicate.new(:mut, :mutation, config: config), %{workspace: ws})

  test "implements the PredicateProvider behaviour" do
    behaviours = Mutation.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  describe "score from counts, gated on a threshold" do
    @report ~s({"summary":{"killed":9,"survived":1},"survivors":[{"file":"lib/x.ex","line":4}]})

    test "score >= threshold -> :pass with the 0-1 score", %{workspace: ws} do
      config = %{
        cmd: "sh",
        args: ["-c", "printf '%s' '#{@report}'; exit 0"],
        threshold: 0.8,
        killed_path: "$.summary.killed",
        survived_path: "$.summary.survived",
        survivors_path: "$.survivors"
      }

      result = evaluate(config, ws)
      assert %PredicateResult{status: :pass} = result
      # 9 killed / 10 total = 0.9.
      assert result.score == 0.9
      assert result.direction == :higher_better
      assert result.evidence.killed == 9
      assert result.evidence.survived == 1
      assert result.evidence.survivors == [%{"file" => "lib/x.ex", "line" => 4}]
    end

    test "score below threshold -> :fail (gated on the PARSED score, not exit)", %{workspace: ws} do
      # The tool exits 0 even though the score is below threshold — the verdict
      # comes from the parsed score, not the exit code.
      report = ~s({"summary":{"killed":5,"survived":5},"survivors":[{"file":"lib/y.ex"}]})

      config = %{
        cmd: "sh",
        args: ["-c", "printf '%s' '#{report}'; exit 0"],
        threshold: 0.8,
        killed_path: "$.summary.killed",
        survived_path: "$.summary.survived",
        survivors_path: "$.survivors"
      }

      result = evaluate(config, ws)
      assert result.status == :fail
      assert result.score == 0.5
      assert result.evidence.survivors == [%{"file" => "lib/y.ex"}]
    end
  end

  describe "score from a precomputed ratio" do
    test "score_path reads a 0-1 score directly", %{workspace: ws} do
      report = ~s({"mutation_score":0.92})

      config = %{
        cmd: "sh",
        args: ["-c", "printf '%s' '#{report}'"],
        threshold: 0.8,
        score_path: "$.mutation_score"
      }

      result = evaluate(config, ws)
      assert result.status == :pass
      assert result.score == 0.92
    end
  end

  describe "empty scope" do
    test "no mutants in scope -> :pass with no score", %{workspace: ws} do
      report = ~s({"summary":{"killed":0,"survived":0}})

      config = %{
        cmd: "sh",
        args: ["-c", "printf '%s' '#{report}'"],
        threshold: 0.8,
        killed_path: "$.summary.killed",
        survived_path: "$.summary.survived"
      }

      result = evaluate(config, ws)
      assert result.status == :pass
      assert result.score == nil
      assert result.evidence.note == :no_mutants_in_scope
    end
  end

  describe "error boundary" do
    test "invalid JSON output is :error, not a silent pass", %{workspace: ws} do
      config = %{
        cmd: "sh",
        args: ["-c", "printf 'not json'; exit 1"],
        threshold: 0.8,
        score_path: "$.x"
      }

      assert evaluate(config, ws).status == :error
    end

    test "a missing binary is :error", %{workspace: ws} do
      config = %{cmd: "definitely-not-a-real-binary-xyz", threshold: 0.8, score_path: "$.x"}
      assert evaluate(config, ws).status == :error
    end
  end

  test "an unsupported kind is an :error" do
    result = Mutation.evaluate(%Predicate{id: :x, kind: :tests, config: %{}}, %{})
    assert result.status == :error
  end
end
