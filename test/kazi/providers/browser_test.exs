defmodule Kazi.Providers.BrowserTest do
  # Tier 2: real boundary, hermetic. The browser runner is the genuine
  # System.cmd seam the provider drives in production; CI has no browser, so the
  # tests inject a STUB program (test/support/stub_playwright.sh) that returns
  # canned JSON over the same subprocess contract the real Node Playwright runner
  # uses. The provider runs its real encode → spawn → parse → map-to-contract
  # path; only the browser itself is replaced (T2.2, UC-012).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Browser

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_browser_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # Build a :browser predicate whose runner command is the stub, with the stub's
  # canned verdict supplied through the provider's real `:env` seam.
  defp predicate(stub_json, extra_config, stub_env) do
    env = [{"STUB_JSON", stub_json} | stub_env]

    config =
      Map.merge(
        %{url: "https://example.test/app", cmd: @stub, args: [], env: env},
        extra_config
      )

    Predicate.new(:ui, :browser, config: config)
  end

  defp evaluate(workspace, stub_json, extra_config \\ %{}, stub_env \\ []) do
    Browser.evaluate(predicate(stub_json, extra_config, stub_env), %{workspace: workspace})
  end

  test "implements the PredicateProvider behaviour" do
    behaviours = Browser.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  # --- Golden path -----------------------------------------------------------

  test "all assertions hold -> :pass with per-assertion evidence", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "pass",
        url: "https://example.test/app",
        assertions: [
          %{type: "visible", selector: "h1", ok: true, expected: "visible", found: "visible"},
          %{type: "text", selector: "h1", ok: true, expected: "Welcome", found: "Welcome"}
        ],
        screenshot: nil,
        error: nil
      })

    result =
      evaluate(ws, verdict, %{
        steps: [%{action: "click", selector: "#start"}],
        assertions: [
          %{type: "visible", selector: "h1"},
          %{type: "text", selector: "h1", contains: "Welcome"}
        ]
      })

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.url == "https://example.test/app"
    assert result.evidence.workspace == ws
    assert length(result.evidence.assertions) == 2
    assert Enum.all?(result.evidence.assertions, & &1["ok"])
  end

  test "tolerates diagnostic noise printed before the JSON verdict", %{workspace: ws} do
    verdict = Jason.encode!(%{status: "pass", assertions: [], screenshot: nil, error: nil})

    result =
      evaluate(ws, verdict, %{}, [{"STUB_NOISE", "launching chromium..."}])

    assert result.status == :pass
  end

  test "records a screenshot path returned by the runner", %{workspace: ws} do
    shot = Path.join(ws, "home.png")

    verdict =
      Jason.encode!(%{status: "pass", assertions: [], screenshot: shot, error: nil})

    result = evaluate(ws, verdict, %{screenshot: shot})

    assert result.status == :pass
    assert result.evidence.screenshot == shot
  end

  # --- Edge case: assertion fails -------------------------------------------

  test "a failing assertion -> :fail (not :error) with expected vs found", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "fail",
        url: "https://example.test/app",
        assertions: [
          %{
            type: "text",
            selector: "h1",
            ok: false,
            expected: "Welcome",
            found: "Error 500"
          }
        ],
        screenshot: nil,
        error: nil
      })

    result =
      evaluate(ws, verdict, %{
        assertions: [%{type: "text", selector: "h1", contains: "Welcome"}]
      })

    assert %PredicateResult{status: :fail} = result
    [assertion] = result.evidence.assertions
    refute assertion["ok"]
    assert assertion["expected"] == "Welcome"
    assert assertion["found"] == "Error 500"
  end

  # --- Edge case: page/launch error -----------------------------------------

  test "a runner 'error' verdict (page/launch failure) -> :error, not :fail", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "error",
        url: "https://example.test/app",
        assertions: [],
        screenshot: nil,
        error: "Timeout 30000ms exceeded navigating to URL"
      })

    result = evaluate(ws, verdict)

    assert %PredicateResult{status: :error} = result
    assert match?({:runner_reported_error, _}, result.evidence.reason)
    assert result.evidence.error =~ "Timeout"
  end

  test "no assertions configured but page loads -> :pass (reachability only)", %{workspace: ws} do
    verdict = Jason.encode!(%{status: "pass", assertions: [], screenshot: nil, error: nil})

    result = evaluate(ws, verdict)

    assert result.status == :pass
    assert result.evidence.assertions == []
  end

  # --- Provider-error paths (infra/config, never :fail) ----------------------

  test "missing :url in config -> :error, not a crash", %{workspace: ws} do
    result =
      Browser.evaluate(Predicate.new(:ui, :browser, config: %{cmd: @stub}), %{workspace: ws})

    assert result.status == :error
    assert result.evidence.reason == :missing_url
  end

  test "runner command not found -> :error, no crash", %{workspace: ws} do
    config = %{
      url: "https://example.test",
      cmd: "kazi_no_such_runner_#{System.unique_integer([:positive])}"
    }

    result = Browser.evaluate(Predicate.new(:ui, :browser, config: config), %{workspace: ws})

    assert %PredicateResult{status: :error} = result
    assert match?({:cmd_unrunnable, _}, result.evidence.reason)
  end

  test "runner exits non-zero (cannot produce verdict) -> :error, not :fail", %{workspace: ws} do
    # Empty STUB_JSON + non-zero exit emulates Playwright missing in the runner.
    config = %{url: "https://example.test", cmd: @stub, args: [], env: [{"STUB_EXIT", "2"}]}
    result = Browser.evaluate(Predicate.new(:ui, :browser, config: config), %{workspace: ws})

    assert result.status == :error
    assert match?({:runner_failed, 2}, result.evidence.reason)
  end

  test "runner prints unparseable output -> :error, not :fail", %{workspace: ws} do
    result =
      Browser.evaluate(
        Predicate.new(:ui, :browser,
          config: %{
            url: "https://example.test",
            cmd: @stub,
            args: [],
            env: [{"STUB_NOISE", "not json at all"}]
          }
        ),
        %{workspace: ws}
      )

    assert result.status == :error
    assert match?({:unparseable_runner_output, _}, result.evidence.reason)
  end

  test "the runner runs in the target workspace", %{workspace: ws} do
    verdict = Jason.encode!(%{status: "pass", assertions: [], screenshot: nil, error: nil})
    result = evaluate(ws, verdict)

    assert result.status == :pass
    assert result.evidence.workspace == ws
  end

  test "non-:browser predicate kind -> :error" do
    result = Browser.evaluate(Predicate.new(:t, :tests), %{})
    assert %PredicateResult{status: :error} = result
    assert match?({:unsupported_kind, :tests}, result.evidence.reason)
  end

  test "defaults workspace to cwd when context omits it" do
    verdict = Jason.encode!(%{status: "pass", assertions: [], screenshot: nil, error: nil})

    result =
      Browser.evaluate(
        Predicate.new(:ui, :browser,
          config: %{
            url: "https://example.test",
            cmd: @stub,
            args: [],
            env: [{"STUB_JSON", verdict}]
          }
        ),
        %{}
      )

    assert result.status == :pass
    assert result.evidence.workspace == File.cwd!()
  end

  # --- synthetic journey (samples > 1, T32.10) -------------------------------

  describe "synthetic journey (samples > 1)" do
    test "X consecutive passing runs -> :pass with score = passing count", %{workspace: ws} do
      pass = Jason.encode!(%{status: "pass", assertions: [], screenshot: nil, error: nil})
      seq_file = write_sequence(ws, [pass, pass, pass])

      result =
        Browser.evaluate(
          predicate(nil, %{samples: 3}, [{"STUB_SEQ_FILE", seq_file}]),
          %{workspace: ws}
        )

      assert %PredicateResult{status: :pass, evidence: evidence} = result
      assert evidence.samples_required == 3
      assert evidence.passing_count == 3
      assert length(evidence.runs) == 3
      assert result.score == 3.0
      assert result.direction == :higher_better
    end

    test "a one-off success among failures is rejected -> :fail", %{workspace: ws} do
      pass = Jason.encode!(%{status: "pass", assertions: [], screenshot: nil, error: nil})
      fail = Jason.encode!(%{status: "fail", assertions: [], screenshot: nil, error: nil})
      seq_file = write_sequence(ws, [pass, fail])

      result =
        Browser.evaluate(
          predicate(nil, %{samples: 3}, [{"STUB_SEQ_FILE", seq_file}]),
          %{workspace: ws}
        )

      assert %PredicateResult{status: :fail, evidence: evidence} = result
      assert evidence.samples_required == 3
      # Only the first run passed before the streak broke.
      assert evidence.passing_count == 1
      assert result.score == 1.0
      assert result.direction == :higher_better
    end

    test "samples: 1 is byte-identical to the single-run path (no score)", %{workspace: ws} do
      verdict = Jason.encode!(%{status: "pass", assertions: [], screenshot: nil, error: nil})
      result = evaluate(ws, verdict, %{samples: 1})

      assert %PredicateResult{status: :pass, score: nil, evidence: evidence} = result
      refute Map.has_key?(evidence, :samples_required)
    end
  end

  # Write a one-verdict-per-line sequence file the stub consumes across runs.
  defp write_sequence(workspace, verdicts) do
    path = Path.join(workspace, "journey_seq_#{System.unique_integer([:positive])}.jsonl")
    File.write!(path, Enum.join(verdicts, "\n") <> "\n")
    path
  end
end
