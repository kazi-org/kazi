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

  # --- download assertion (T49.10, ADR-0064 d7, UC-066) ----------------------
  #
  # Same division of labour as console_clean: the assertion vocabulary lives in
  # the runner (kazi passes `assertions` verbatim, the ADR-0040 dividend), so what
  # the PROVIDER owes is the mapping — a matching download passes, a missing or
  # wrong-named one is real failing UI work (:fail) carrying the expected-vs-found
  # evidence, and a runner that could not produce a verdict is :error.

  describe "download assertion" do
    test "a matching download (ok: true) -> :pass, with the file's identity as evidence", %{
      workspace: ws
    } do
      found = %{
        filename: "invoice-2026-07.csv",
        sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        path: "/tmp/pw-dl/invoice-2026-07.csv"
      }

      verdict =
        Jason.encode!(%{
          status: "pass",
          url: "https://app.test/reports",
          assertions: [
            %{type: "download", ok: true, expected: "^invoice-\\d{4}-\\d{2}\\.csv$", found: found}
          ],
          screenshot: nil,
          error: nil
        })

      result =
        evaluate(ws, verdict, %{
          assertions: [%{type: "download", filename_pattern: "^invoice-\\d{4}-\\d{2}\\.csv$"}]
        })

      assert %PredicateResult{status: :pass} = result
      assert [assertion] = result.evidence.assertions
      assert assertion["type"] == "download"
      assert assertion["ok"]
      # The sha256 is what makes "the RIGHT file" checkable, not merely "a file
      # with the right name" — so it must survive into the evidence.
      assert assertion["found"]["filename"] == "invoice-2026-07.csv"
      assert assertion["found"]["sha256"] =~ ~r/^[a-f0-9]+$/
    end

    test "no download within the timeout (ok: false) -> :fail, not :error", %{workspace: ws} do
      verdict =
        Jason.encode!(%{
          status: "fail",
          url: "https://app.test/reports",
          assertions: [
            %{type: "download", ok: false, expected: "^invoice-.*\\.csv$", found: nil}
          ],
          screenshot: nil,
          error: nil
        })

      result =
        evaluate(ws, verdict, %{
          assertions: [%{type: "download", filename_pattern: "^invoice-.*\\.csv$"}]
        })

      # The page ran and simply did not deliver the file: failing WORK, which
      # should dispatch a fixer agent — never :error, which would blame infra.
      assert %PredicateResult{status: :fail} = result
      assert [assertion] = result.evidence.assertions
      refute assertion["ok"]
      assert assertion["expected"] == "^invoice-.*\\.csv$"
      assert assertion["found"] == nil
    end

    test "a wrong-named download -> :fail carrying expected VS found", %{workspace: ws} do
      verdict =
        Jason.encode!(%{
          status: "fail",
          url: "https://app.test/reports",
          assertions: [
            %{
              type: "download",
              ok: false,
              expected: "^invoice-\\d{4}-\\d{2}\\.csv$",
              found: %{filename: "error-page.html", sha256: "abc123", path: "/tmp/x.html"}
            }
          ],
          screenshot: nil,
          error: nil
        })

      result =
        evaluate(ws, verdict, %{
          assertions: [%{type: "download", filename_pattern: "^invoice-\\d{4}-\\d{2}\\.csv$"}]
        })

      assert %PredicateResult{status: :fail} = result
      assert [assertion] = result.evidence.assertions
      # Both halves must be present: a fixer agent needs to see what it asked for
      # AND what it got. "false" alone is not actionable.
      assert assertion["expected"] == "^invoice-\\d{4}-\\d{2}\\.csv$"
      assert assertion["found"]["filename"] == "error-page.html"
    end
  end

  # --- console_clean assertion (T43.1, ADR-0053 §1, UC-056) ------------------
  #
  # The assertion vocabulary lives in the runner (kazi passes `assertions`
  # verbatim), so what the PROVIDER owes is the mapping: a clean journey passes, a
  # captured error is real failing UI work (:fail) carrying the offenders as
  # evidence, and a runner that could not produce a verdict at all is :error --
  # never a :fail that would dispatch a fixer agent at an infra problem.

  describe "console_clean assertion" do
    test "a clean journey (ok: true) -> :pass", %{workspace: ws} do
      verdict =
        Jason.encode!(%{
          status: "pass",
          url: "https://example.test/app",
          assertions: [%{type: "console_clean", ok: true, expected: 0, found: []}],
          screenshot: nil,
          error: nil
        })

      result = evaluate(ws, verdict, %{assertions: [%{type: "console_clean"}]})

      assert %PredicateResult{status: :pass} = result
      assert [assertion] = result.evidence.assertions
      assert assertion["type"] == "console_clean"
      assert assertion["ok"]
      assert assertion["found"] == []
    end

    test "captured console errors (ok: false) -> :fail with the offenders as evidence", %{
      workspace: ws
    } do
      found = [
        %{kind: "console.error", text: "Uncaught TypeError: x is not a function", location: nil},
        %{kind: "console.error", text: "Failed to load resource", location: nil}
      ]

      verdict =
        Jason.encode!(%{
          status: "fail",
          url: "https://example.test/app",
          assertions: [%{type: "console_clean", ok: false, expected: 0, found: found}],
          screenshot: nil,
          error: nil
        })

      result = evaluate(ws, verdict, %{assertions: [%{type: "console_clean"}]})

      # A console error the page really produced is failing WORK, not infra.
      assert %PredicateResult{status: :fail} = result
      assert [assertion] = result.evidence.assertions
      refute assertion["ok"]
      assert assertion["expected"] == 0
      assert length(assertion["found"]) == 2
      assert hd(assertion["found"])["text"] =~ "Uncaught TypeError"
    end

    test "a failed 4xx/5xx response is reported when network: true -> :fail", %{workspace: ws} do
      verdict =
        Jason.encode!(%{
          status: "fail",
          url: "https://example.test/app",
          assertions: [
            %{
              type: "console_clean",
              ok: false,
              expected: 0,
              found: [%{kind: "network", status: 500, url: "https://example.test/api/cart"}]
            }
          ],
          screenshot: nil,
          error: nil
        })

      result =
        evaluate(ws, verdict, %{assertions: [%{type: "console_clean", network: true}]})

      assert %PredicateResult{status: :fail} = result
      assert [%{"found" => [failure]}] = result.evidence.assertions
      assert failure["status"] == 500
      assert failure["kind"] == "network"
    end

    test "a runner crash under a console_clean assertion -> :error, never :fail", %{
      workspace: ws
    } do
      # Non-zero exit with no verdict: the runner could not evaluate the journey
      # at all (e.g. Playwright missing). Reporting :fail here would send a fixer
      # agent hunting a console error that was never observed.
      result =
        Browser.evaluate(
          predicate(nil, %{assertions: [%{type: "console_clean"}]}, [{"STUB_EXIT", "2"}]),
          %{workspace: ws}
        )

      assert %PredicateResult{status: :error} = result
      assert match?({:runner_failed, 2}, result.evidence.reason)
    end
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
