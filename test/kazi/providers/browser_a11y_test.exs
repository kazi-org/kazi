defmodule Kazi.Providers.BrowserA11yTest do
  @moduledoc """
  T43.2 (UC-056): the `a11y` browser assertion. Tier 2, hermetic — the provider's
  real encode → spawn → parse → map-to-contract path runs against the shared
  `stub_playwright.sh`, which returns the canned runner verdict the real axe-core
  run would produce (CI has no browser / axe-core). Proves the PROVIDER maps an
  a11y verdict to the contract: the violation count becomes a `lower_better` score,
  N > max_violations fails with per-violation evidence, and an "axe-core missing"
  run is `:error` (never `:fail`). The runner's own axe-core invocation is
  exercised end-to-end only in the Tier-4 dogfood.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Browser

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_a11y_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp evaluate(workspace, verdict, assertions) do
    config = %{
      url: "https://example.test/app",
      cmd: @stub,
      args: [],
      env: [{"STUB_JSON", verdict}],
      assertions: assertions
    }

    Browser.evaluate(Predicate.new(:ui, :browser, config: config), %{workspace: workspace})
  end

  test "zero violations -> :pass with score 0.0 (lower_better)", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "pass",
        url: "https://example.test/app",
        assertions: [%{type: "a11y", ok: true, expected: 0, found: [], count: 0}],
        screenshot: nil,
        error: nil
      })

    result = evaluate(ws, verdict, [%{type: "a11y"}])

    assert %PredicateResult{status: :pass, direction: :lower_better} = result
    assert result.score == 0.0
  end

  test "N > max_violations -> :fail with score N and per-violation evidence", %{workspace: ws} do
    violations = [
      %{id: "color-contrast", impact: "serious", nodes: ["main > p.muted"]},
      %{id: "label", impact: "critical", nodes: ["form > input#email"]},
      %{id: "aria-roles", impact: "serious", nodes: ["div[role=buton]"]}
    ]

    verdict =
      Jason.encode!(%{
        status: "fail",
        url: "https://example.test/app",
        assertions: [%{type: "a11y", ok: false, expected: 0, found: violations, count: 3}],
        screenshot: nil,
        error: nil
      })

    result = evaluate(ws, verdict, [%{type: "a11y", max_violations: 0}])

    assert %PredicateResult{status: :fail, score: 3.0, direction: :lower_better} = result
    assert [a11y] = result.evidence.assertions
    assert a11y["count"] == 3
    assert Enum.map(a11y["found"], & &1["id"]) == ["color-contrast", "label", "aria-roles"]
    assert hd(a11y["found"])["nodes"] == ["main > p.muted"]
  end

  test "axe-core missing on the runner side -> :error, never :fail", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "error",
        url: "https://example.test/app",
        assertions: [%{type: "a11y", unavailable: true, ok: false, found: []}],
        screenshot: nil,
        error: "a11y unavailable"
      })

    result = evaluate(ws, verdict, [%{type: "a11y"}])

    assert %PredicateResult{status: :error} = result
    assert {:runner_reported_error, "a11y unavailable"} = result.evidence.reason
  end

  test "no a11y assertion -> no score (byte-identical boolean result)", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "pass",
        url: "https://example.test/app",
        assertions: [%{type: "visible", selector: "h1", ok: true}],
        screenshot: nil,
        error: nil
      })

    result = evaluate(ws, verdict, [%{type: "visible", selector: "h1"}])

    assert %PredicateResult{status: :pass, score: nil, direction: nil} = result
  end
end
