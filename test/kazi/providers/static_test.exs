defmodule Kazi.Providers.StaticTest do
  @moduledoc """
  The `:static` provider (T32.7, ADR-0043): Dialyzer-led static analysis,
  generalized to the polyglot SARIF tools, gated on PARSED findings (not the exit
  code) with a baseline ratchet on NEW findings.

  Per the task rule, the acceptance is exercised with FIXTURES (a stub `cmd` that
  emits canned Dialyzer/SARIF output), never a live Dialyzer run — so CI needs no
  PLT.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Evidence, Predicate, PredicateResult}
  alias Kazi.Goal.Loader
  alias Kazi.Providers.Static
  alias Kazi.Ratchet.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_static_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # A Dialyzer report with two findings (short format), the worse-than-clean case.
  @two_warnings """
  lib/kazi/foo.ex:23:no_return Function bar/0 has no local return.
  lib/kazi/baz.ex:10:7:pattern_match The pattern can never match the type.
  """

  @one_warning "lib/kazi/foo.ex:23:no_return Function bar/0 has no local return.\n"

  # A SARIF log with one error finding.
  @sarif_one_error ~s({"runs":[{"results":[{"ruleId":"no-explicit-any","level":"error",) <>
                     ~s("message":{"text":"Unexpected any"},"locations":[{"physicalLocation":) <>
                     ~s({"artifactLocation":{"uri":"src/a.ts"},"region":{"startLine":12,) <>
                     ~s("startColumn":5}}}]}]}]})

  @sarif_clean ~s({"runs":[{"results":[]}]})

  # Build a config whose analyzer is a stub that prints `output` then exits `code`,
  # proving the verdict is gated on PARSED findings, not the exit code.
  defp analyzer(ws, output, code) do
    file = Path.join(ws, "report-#{System.unique_integer([:positive])}.txt")
    File.write!(file, output)
    %{cmd: "sh", args: ["-c", "cat '#{file}'; exit #{code}"]}
  end

  defp evaluate(config, ws, context \\ %{}) do
    Static.evaluate(
      Predicate.new(:analysis, :static, config: config),
      Map.merge(%{workspace: ws}, context)
    )
  end

  test "implements the PredicateProvider behaviour" do
    behaviours = Static.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  describe "Dialyzer zero-findings gate (no baseline)" do
    test "a fresh warning yields :fail with a localized evidence item", %{workspace: ws} do
      # Exit 2 (Dialyzer's warnings-present code) — the verdict must come from the
      # parsed findings, NOT the exit code.
      result = evaluate(analyzer(ws, @one_warning, 2), ws)

      assert %PredicateResult{status: :fail, score: 1.0, direction: :lower_better} = result
      assert result.evidence.findings_count == 1
      assert result.evidence.gate == :zero_findings

      assert [
               %Evidence{file: "lib/kazi/foo.ex", line: 23, rule: "no_return", level: :warning} =
                 item
             ] =
               result.diagnostics

      assert item.message =~ "no local return"
    end

    test "a clean run yields :pass with no findings", %{workspace: ws} do
      result = evaluate(analyzer(ws, "", 0), ws)

      assert %PredicateResult{status: :pass, direction: :lower_better} = result
      assert result.score == 0.0
      assert result.evidence.findings_count == 0
      assert result.diagnostics == []
    end

    test "a two-line report localizes both findings, including the column", %{workspace: ws} do
      result = evaluate(analyzer(ws, @two_warnings, 2), ws)

      assert result.status == :fail
      assert result.evidence.findings_count == 2

      assert [_, %Evidence{file: "lib/kazi/baz.ex", line: 10, col: 7, rule: "pattern_match"}] =
               result.diagnostics
    end
  end

  describe "SARIF format (the polyglot path, via the shared parser)" do
    test "a SARIF log with a finding fails with a localized evidence item", %{workspace: ws} do
      # SARIF tools commonly exit 0 WITH findings — the verdict must still be :fail.
      result = evaluate(Map.put(analyzer(ws, @sarif_one_error, 0), :format, "sarif"), ws)

      assert result.status == :fail
      assert result.score == 1.0

      assert [
               %Evidence{
                 file: "src/a.ts",
                 line: 12,
                 col: 5,
                 rule: "no-explicit-any",
                 level: :error
               }
             ] =
               result.diagnostics
    end

    test "a clean SARIF log passes", %{workspace: ws} do
      result = evaluate(Map.put(analyzer(ws, @sarif_clean, 0), :format, "sarif"), ws)
      assert result.status == :pass
      assert result.evidence.findings_count == 0
    end

    test "malformed SARIF is :error, never a silent pass", %{workspace: ws} do
      result = evaluate(Map.put(analyzer(ws, "not json", 0), :format, "sarif"), ws)
      assert result.status == :error
      assert result.evidence.reason
    end
  end

  describe "baseline ratchet on NEW findings (reuses Kazi.Ratchet, T32.3)" do
    test "a number baseline ignores pre-existing findings and fails only on new ones",
         %{workspace: ws} do
      # Baseline = 2 known pre-existing findings. A run still at 2 passes (the
      # pre-existing debt is ignored); a third (NEW) finding fails.
      at_baseline = evaluate(Map.put(analyzer(ws, @two_warnings, 2), :baseline, 2), ws)
      assert at_baseline.status == :pass
      assert at_baseline.evidence.baseline == 2.0
      assert at_baseline.evidence.regression == 0.0
      assert at_baseline.evidence.new_findings == 0.0

      three = @two_warnings <> "lib/kazi/qux.ex:5:call A new finding.\n"
      regressed = evaluate(Map.put(analyzer(ws, three, 2), :baseline, 2), ws)
      assert regressed.status == :fail
      assert regressed.evidence.regression == 1.0
      assert regressed.evidence.new_findings == 1.0
    end

    test "allowed_regression tolerates that many new findings", %{workspace: ws} do
      three = @two_warnings <> "lib/kazi/qux.ex:5:call A new finding.\n"
      config = analyzer(ws, three, 2) |> Map.merge(%{baseline: 2, allowed_regression: 1})
      result = evaluate(config, ws)
      assert result.status == :pass
      assert result.evidence.new_findings == 1.0
    end

    test "a stored baseline seeds on the first run then fails on a new finding",
         %{workspace: ws} do
      config = Map.put(analyzer(ws, @two_warnings, 2), :baseline, "stored")

      first = evaluate(config, ws)
      assert first.status == :pass
      assert first.evidence.baseline_source == :seed
      assert first.evidence.stored == true
      assert Store.read(Path.join(ws, ".kazi"), :analysis) == {:ok, 2.0}

      # A later run with a NEW finding fails — the stored floor stays at 2.
      three = @two_warnings <> "lib/kazi/qux.ex:5:call A new finding.\n"
      regressed = evaluate(Map.put(analyzer(ws, three, 2), :baseline, "stored"), ws)
      assert regressed.status == :fail
      assert regressed.evidence.baseline == 2.0
      assert regressed.evidence.regression == 1.0
      assert Store.read(Path.join(ws, ".kazi"), :analysis) == {:ok, 2.0}
    end

    test "a stored baseline tightens the floor when a finding is removed", %{workspace: ws} do
      stored = Map.put(analyzer(ws, @two_warnings, 2), :baseline, "stored")
      assert evaluate(stored, ws).evidence.baseline_source == :seed

      improved = evaluate(Map.put(analyzer(ws, @one_warning, 2), :baseline, "stored"), ws)
      assert improved.status == :pass
      assert improved.evidence.stored == true
      assert Store.read(Path.join(ws, ".kazi"), :analysis) == {:ok, 1.0}
    end

    test "the store dir is relocatable via context (anti-gaming, T32.4)", %{workspace: ws} do
      store = Path.join(ws, "clean-store")
      config = Map.put(analyzer(ws, @one_warning, 2), :baseline, "stored")

      evaluate(config, ws, %{ratchet_store_dir: store})
      assert Store.read(store, :analysis) == {:ok, 1.0}
      assert Store.read(Path.join(ws, ".kazi"), :analysis) == :none
    end
  end

  describe "git-ref baseline (new findings vs a commit, recomputed in a worktree)" do
    test "a finding added since the ref fails; no new findings passes", %{workspace: ws} do
      repo = init_git_repo!(ws)
      # cmd reads the committed report so it differs per ref/worktree.
      config = %{cmd: "sh", args: ["-c", "cat report.txt"], baseline: "HEAD~1"}

      # HEAD has two findings, HEAD~1 had one -> one NEW finding -> :fail.
      regressed = evaluate(config, repo)
      assert regressed.status == :fail
      assert regressed.evidence.baseline_source == :git_ref
      assert regressed.evidence.baseline == 1.0
      assert regressed.evidence.regression == 1.0
    end
  end

  describe "error vs failure boundary" do
    test "a missing analyzer binary is :error, never :fail", %{workspace: ws} do
      result = evaluate(%{cmd: "definitely-not-a-real-binary-xyz"}, ws)
      assert result.status == :error
      assert {:cmd_unrunnable, _} = result.evidence.reason
    end

    test "a declared error_code maps to :error before findings are read", %{workspace: ws} do
      config = Map.put(analyzer(ws, @one_warning, 3), :error_codes, [3])
      result = evaluate(config, ws)
      assert result.status == :error
      assert result.evidence.reason == {:error_exit, 3}
    end

    test "an unsupported kind is an :error (defensive)" do
      result = Static.evaluate(Predicate.new(:x, :tests, config: %{}), %{})
      assert %PredicateResult{status: :error} = result
      assert {:unsupported_kind, :tests} = result.evidence.reason
    end
  end

  describe "loader validation (load-time loud, T32.7)" do
    test "a valid static predicate loads with kind :static" do
      goal = %{
        "id" => "g",
        "predicate" => [
          %{
            "id" => "analysis",
            "provider" => "static",
            "cmd" => "mix",
            "args" => ["dialyzer", "--format", "short"]
          }
        ]
      }

      assert {:ok, %{predicates: [%Predicate{kind: :static}]}} = Loader.from_map(goal)
    end

    test "a missing cmd is a load error" do
      goal = %{"id" => "g", "predicate" => [%{"id" => "a", "provider" => "static"}]}
      assert {:error, reason} = Loader.from_map(goal)
      assert reason =~ "requires a non-empty string \"cmd\""
    end

    test "an unknown format is a load error" do
      goal = %{
        "id" => "g",
        "predicate" => [%{"id" => "a", "provider" => "static", "cmd" => "x", "format" => "lsp"}]
      }

      assert {:error, reason} = Loader.from_map(goal)
      assert reason =~ "unknown format"
    end

    test "a non-numeric allowed_regression is a load error" do
      goal = %{
        "id" => "g",
        "predicate" => [
          %{"id" => "a", "provider" => "static", "cmd" => "x", "allowed_regression" => "lots"}
        ]
      }

      assert {:error, reason} = Loader.from_map(goal)
      assert reason =~ "allowed_regression"
    end
  end

  describe "kazi schema static" do
    test "is registered and lists the documented keys" do
      assert "static" in Kazi.Predicate.Schema.kinds()
      assert {:ok, schema} = Kazi.Predicate.Schema.fetch("static")
      assert schema.kind == "static"

      names = Enum.map(schema.keys, & &1.name)
      assert "cmd" in names
      assert "format" in names
      assert "baseline" in names
      assert "allowed_regression" in names

      assert Enum.find(schema.keys, &(&1.name == "cmd")).required == true
    end
  end

  # A two-commit git repo: HEAD~1 has one finding, HEAD has two. Returns the repo
  # path (a worktree of `parent`).
  defp init_git_repo!(parent) do
    repo = Path.join(parent, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    git!(repo, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(repo, "report.txt"), @one_warning)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "one finding"])

    File.write!(Path.join(repo, "report.txt"), @two_warnings)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "two findings"])

    repo
  end

  defp git!(repo, args) do
    {_out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  end
end
