defmodule Kazi.Providers.CveTest do
  # Tier 2: real boundary. These run a command that emits RECORDED scanner output
  # (a govulncheck -json finding stream; an npm-audit JSON report) and assert the
  # resulting PredicateResult, proving the :cve provider gates on the PARSED output
  # and NOT the exit code: govulncheck -json exits 0 even with vulns (L-0015), so
  # a reachable finding must still fail. No live scanner is needed (T32.8,
  # ADR-0043).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Cve

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_cve_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp emit(ws, output, code) do
    fixture = Path.join(ws, "out-#{System.unique_integer([:positive])}.json")
    File.write!(fixture, output)
    fn extra -> Map.merge(%{cmd: "sh", args: ["-c", "cat '#{fixture}'; exit #{code}"]}, extra) end
  end

  defp evaluate(config, ws),
    do:
      Cve.evaluate(Predicate.new(:cve, :cve, config: config), %{
        workspace: ws,
        ratchet_store_dir: ws
      })

  # A govulncheck -json stream: concatenated pretty-printed objects (config +
  # findings), NOT a single document.
  @reachable_stream """
  {
    "config": { "protocol_version": "v1.0.0", "scanner_name": "govulncheck" }
  }
  {
    "finding": {
      "osv": "GO-2021-0113",
      "fixed_version": "v0.3.7",
      "trace": [
        {
          "module": "golang.org/x/text",
          "version": "v0.3.5",
          "package": "golang.org/x/text/language",
          "function": "Parse",
          "position": { "filename": "main.go", "line": 20, "column": 2 }
        },
        {
          "module": "example.com/app",
          "package": "example.com/app",
          "function": "main"
        }
      ]
    }
  }
  """

  # An OSV imported but not CALLED: the trace leaf carries no `function`, only the
  # package — govulncheck does not consider it reachable.
  @unreachable_stream """
  {
    "config": { "scanner_name": "govulncheck" }
  }
  {
    "finding": {
      "osv": "GO-2022-0999",
      "trace": [
        { "module": "example.com/unused", "package": "example.com/unused/pkg" }
      ]
    }
  }
  """

  @clean_stream """
  {
    "config": { "scanner_name": "govulncheck" }
  }
  {
    "progress": { "message": "Scanning your code and dependencies" }
  }
  """

  test "implements the PredicateProvider behaviour" do
    behaviours = Cve.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  describe "tier 1 — govulncheck reachability (gated on parsed output, not exit code)" do
    test "a reachable vuln FAILS with the call stack as evidence — even at exit 0", %{
      workspace: ws
    } do
      # The exit-0 gotcha: govulncheck -json exits 0 WITH vulns. The verdict comes
      # from the parsed finding stream.
      config = emit(ws, @reachable_stream, 0).(%{tool: "govulncheck"})
      result = evaluate(config, ws)

      assert %PredicateResult{status: :fail} = result
      assert result.score == 1.0
      assert result.direction == :lower_better
      assert result.evidence.reachable == 1

      [finding] = result.evidence.findings
      assert finding.osv == "GO-2021-0113"
      assert finding.file == "main.go"
      assert finding.line == 20
      # The call stack (the proof) walks leaf -> root.
      assert "Parse@golang.org/x/text/language" in finding.call_stack
      # A diagnostic carries the reachable finding for the fixer.
      assert [%Kazi.Evidence{rule: "GO-2021-0113", level: :error}] = result.diagnostics
    end

    test "an imported-but-not-called vuln does NOT fail (reachability filters it)", %{
      workspace: ws
    } do
      config = emit(ws, @unreachable_stream, 0).(%{tool: "govulncheck"})
      result = evaluate(config, ws)
      assert result.status == :pass
      assert result.evidence.reachable == 0
    end

    test "no findings -> :pass with score 0", %{workspace: ws} do
      config = emit(ws, @clean_stream, 0).(%{tool: "govulncheck"})
      result = evaluate(config, ws)
      assert result.status == :pass
      assert result.score == 0.0
    end

    test "a non-zero exit with NO parseable output is :error (tool could not run)", %{
      workspace: ws
    } do
      config = emit(ws, "govulncheck: failed to load packages\n", 1).(%{tool: "govulncheck"})
      result = evaluate(config, ws)
      assert result.status == :error
    end

    test "a missing binary is :error", %{workspace: ws} do
      result =
        evaluate(%{tool: "govulncheck", cmd: "definitely-not-a-real-binary-xyz", args: []}, ws)

      assert result.status == :error
    end
  end

  describe "tier 2 — manifest scanner ratcheted vs a baseline" do
    @npm_report ~s({"metadata":{"vulnerabilities":{"total":3,"critical":0,"high":1}}})

    test "count within the baseline passes (gated on parsed count, not exit)", %{workspace: ws} do
      # npm audit exits NON-zero WITH findings; the verdict is the parsed count.
      config =
        emit(ws, @npm_report, 1).(%{
          tool: "npm_audit",
          count_path: "$.metadata.vulnerabilities.total",
          baseline: 5
        })

      result = evaluate(config, ws)
      assert result.status == :pass
      assert result.score == 3.0
      assert result.direction == :lower_better
      assert result.evidence.count == 3
    end

    test "count above the baseline fails", %{workspace: ws} do
      config =
        emit(ws, @npm_report, 1).(%{
          tool: "npm_audit",
          count_path: "$.metadata.vulnerabilities.total",
          baseline: 2
        })

      assert evaluate(config, ws).status == :fail
    end

    test "a stored baseline seeds on the first run, then ratchets", %{workspace: ws} do
      cfg = fn count ->
        report = ~s({"metadata":{"vulnerabilities":{"total":#{count}}}})

        %{
          tool: "npm_audit",
          cmd: "sh",
          args: ["-c", "printf '%s' '#{report}'; exit 1"],
          count_path: "$.metadata.vulnerabilities.total",
          baseline: "stored",
          id: "cve-ratchet"
        }
      end

      # First run seeds the baseline at 4 (passes).
      assert evaluate(cfg.(4), ws).status == :pass
      # A drop to 2 passes and tightens the baseline.
      assert evaluate(cfg.(2), ws).status == :pass
      # A rise back to 3 now exceeds the tightened baseline (2) and fails.
      assert evaluate(cfg.(3), ws).status == :fail
    end

    test "a missing count in the JSON is :error, never a silent pass", %{workspace: ws} do
      config =
        emit(ws, ~s({"metadata":{}}), 1).(%{
          tool: "npm_audit",
          count_path: "$.metadata.vulnerabilities.total",
          baseline: 0
        })

      assert evaluate(config, ws).status == :error
    end
  end

  describe "decode_stream/1" do
    test "splits concatenated objects and ignores braces inside strings" do
      stream = ~s({"a":"has } brace"}\n{"b":2})
      assert [%{"a" => "has } brace"}, %{"b" => 2}] = Cve.decode_stream(stream)
    end
  end

  test "an unsupported kind is an :error" do
    result = Cve.evaluate(%Predicate{id: :x, kind: :tests, config: %{}}, %{})
    assert result.status == :error
  end
end
