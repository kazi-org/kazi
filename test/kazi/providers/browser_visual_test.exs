defmodule Kazi.Providers.BrowserVisualTest do
  @moduledoc """
  T43.3 (UC-056): the `visual` baseline-diff browser assertion. Tier 2, hermetic —
  the provider's real encode → spawn → parse → map-to-contract path runs against
  the shared `stub_playwright.sh`, which returns the canned runner verdict the real
  pixel-diff would produce. Proves the PROVIDER mapping: an under-threshold diff
  passes, an over-threshold diff fails with the diff image path in the evidence,
  and a seeded (no-baseline) run is `:error` "baseline seeded" — never a false
  pass. The runner's real screenshot + pixelmatch path is exercised in the Tier-4
  live test.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Browser

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_visual_#{System.unique_integer([:positive])}")
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

  test "an under-threshold diff -> :pass", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "pass",
        url: "https://example.test/app",
        assertions: [
          %{
            type: "visual",
            ok: true,
            expected: %{threshold: 0.01},
            found: %{diff_ratio: 0.002, diff_pixels: 40, total_pixels: 20000, diff_path: nil}
          }
        ],
        screenshot: nil,
        error: nil
      })

    assert %PredicateResult{status: :pass} =
             evaluate(ws, verdict, [%{type: "visual", name: "home"}])
  end

  test "an over-threshold diff -> :fail with the diff image path in evidence", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "fail",
        url: "https://example.test/app",
        assertions: [
          %{
            type: "visual",
            ok: false,
            expected: %{threshold: 0.01},
            found: %{
              diff_ratio: 0.21,
              diff_pixels: 4200,
              total_pixels: 20000,
              diff_path: ".kazi/visual-diffs/home.png"
            }
          }
        ],
        screenshot: nil,
        error: nil
      })

    result = evaluate(ws, verdict, [%{type: "visual", name: "home", threshold: 0.01}])

    assert %PredicateResult{status: :fail} = result
    assert [visual] = result.evidence.assertions
    assert visual["found"]["diff_path"] == ".kazi/visual-diffs/home.png"
    assert visual["found"]["diff_ratio"] == 0.21
  end

  test "a missing baseline is :error \"baseline seeded\", never :fail or :pass", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "error",
        url: "https://example.test/app",
        error: "baseline seeded",
        assertions: [
          %{
            type: "visual",
            fatal: true,
            error: "baseline seeded",
            ok: false,
            expected: ".kazi/visual-baselines/home.png",
            found: %{baseline: ".kazi/visual-baselines/home.png", seeded: true}
          }
        ],
        screenshot: nil
      })

    result = evaluate(ws, verdict, [%{type: "visual", name: "home"}])

    assert %PredicateResult{status: :error} = result
    assert {:runner_reported_error, "baseline seeded"} = result.evidence.reason
  end

  test "a missing pixel-diff dependency is :error, never :fail", %{workspace: ws} do
    verdict =
      Jason.encode!(%{
        status: "error",
        url: "https://example.test/app",
        error: "visual diff unavailable",
        assertions: [%{type: "visual", fatal: true, error: "visual diff unavailable", ok: false}],
        screenshot: nil
      })

    result = evaluate(ws, verdict, [%{type: "visual", name: "home"}])

    assert %PredicateResult{status: :error} = result
    assert {:runner_reported_error, "visual diff unavailable"} = result.evidence.reason
  end
end
