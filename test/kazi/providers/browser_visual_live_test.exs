defmodule Kazi.Providers.BrowserVisualLiveTest do
  # The REAL runner: a REAL Chromium screenshot pixel-diffed with REAL
  # pixelmatch/pngjs against a committed baseline on disk (T43.3, UC-056). The
  # hermetic visual suite injects the stub runner, proving the provider mapping but
  # never that the runner actually screenshots, seeds a missing baseline, and
  # diffs — that is the JavaScript the stub can only imitate. This is that proof,
  # including the critical seed-on-first-run invariant.
  #
  # Tagged `:browser_live` and EXCLUDED by default. Opt in (needs the runner deps):
  #
  #     npm i playwright pixelmatch pngjs && npx playwright install chromium
  #     mix test --only browser_live test/kazi/providers/browser_visual_live_test.exs
  #
  # Probes for node + playwright + pixelmatch + pngjs first and SKIPS HONESTLY when
  # any is missing — never fails, never fake-passes.
  use ExUnit.Case, async: false

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Browser

  @moduletag :browser_live
  @moduletag timeout: 180_000

  @runner Path.expand("../../../priv/browser/playwright_runner.js", __DIR__)

  setup_all do
    if deps_available?(), do: :ok, else: {:ok, skip: true}
  end

  setup context do
    if context[:skip] do
      :ok
    else
      docroot =
        Path.join(System.tmp_dir!(), "kazi_visual_live_#{System.unique_integer([:positive])}")

      File.mkdir_p!(docroot)
      on_exit(fn -> File.rm_rf!(docroot) end)
      {:ok, docroot: docroot, port: serve(docroot)}
    end
  end

  @tag :browser_live
  test "seeds a missing baseline (:error), then matches it (:pass), then diffs a change (:fail)",
       context do
    if skipped?(context) do
      :ok
    else
      %{docroot: docroot, port: port} = context
      name = "hero"
      baseline = Path.join([docroot, ".kazi", "visual-baselines", "#{name}.png"])

      write(docroot, "page.html", page_html("#3366cc", "Welcome"))
      url = "http://127.0.0.1:#{port}/page.html"
      assertions = [%{type: "visual", name: name, selector: "#box"}]

      # 1) No baseline yet → SEED it and :error "baseline seeded". Never a pass.
      seeded = drive(docroot, url, %{assertions: assertions})
      assert %PredicateResult{status: :error} = seeded
      assert {:runner_reported_error, "baseline seeded"} = seeded.evidence.reason
      assert File.exists?(baseline), "the baseline must have been written on the first run"

      # 2) Same page against the now-committed baseline → :pass.
      matched = drive(docroot, url, %{assertions: assertions})
      assert %PredicateResult{status: :pass} = matched

      # 3) Change the box's colour → an over-threshold diff → :fail with a diff path.
      write(docroot, "page.html", page_html("#cc3333", "Welcome"))

      changed =
        drive(docroot, url, %{
          assertions: [%{type: "visual", name: name, selector: "#box", threshold: 0.0}]
        })

      assert %PredicateResult{status: :fail} = changed
      assert [visual] = changed.evidence.assertions
      refute visual["ok"]
      diff_path = visual["found"]["diff_path"]
      assert is_binary(diff_path)

      assert File.exists?(Path.join(docroot, diff_path)),
             "the diff image must be written on a fail"
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp page_html(color, text) do
    """
    <!doctype html><html lang="en"><head><title>Visual</title></head><body>
      <div id="box" style="width:200px;height:100px;background:#{color};color:#fff;font:16px sans-serif;">#{text}</div>
    </body></html>
    """
  end

  defp drive(docroot, url, config) do
    Browser.evaluate(
      Predicate.new(:ui, :browser, config: Map.merge(%{url: url, args: [@runner]}, config)),
      %{workspace: docroot}
    )
  end

  defp write(docroot, name, body), do: File.write!(Path.join(docroot, name), body)

  defp serve(docroot) do
    {:ok, _} = :application.ensure_all_started(:inets)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi_visual_live",
        server_root: String.to_charlist(docroot),
        document_root: String.to_charlist(docroot),
        bind_address: ~c"127.0.0.1"
      )

    on_exit(fn -> :inets.stop(:httpd, pid) end)
    :proplists.get_value(:port, :httpd.info(pid))
  end

  defp skipped?(context) do
    if context[:skip] do
      IO.puts(
        "\n  [skipped] node + playwright + pixelmatch + pngjs unavailable — the real runner was NOT exercised"
      )

      true
    else
      false
    end
  end

  defp deps_available? do
    case System.cmd(
           "node",
           [
             "-e",
             "require.resolve('playwright'); require.resolve('pixelmatch'); require.resolve('pngjs')"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end
end
