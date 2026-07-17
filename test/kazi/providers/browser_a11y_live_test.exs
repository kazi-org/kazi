defmodule Kazi.Providers.BrowserA11yLiveTest do
  # The REAL runner, running REAL axe-core against a REAL Chromium (T43.2, UC-056).
  # The hermetic a11y suite injects the stub runner, proving the provider's mapping
  # but never that the runner actually RUNS axe-core, ranks by impact, and shapes
  # the violation records — that is JavaScript the stub can only imitate. This is
  # that proof.
  #
  # Tagged `:browser_live` and EXCLUDED by default so `mix test` and CI stay
  # hermetic. Opt in explicitly (requires the runner's own optional deps):
  #
  #     npm i playwright axe-core && npx playwright install chromium
  #     mix test --only browser_live test/kazi/providers/browser_a11y_live_test.exs
  #
  # It probes for node + playwright + axe-core first and SKIPS HONESTLY when any is
  # missing — it never fails and never fake-passes on a machine without them.
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
        Path.join(System.tmp_dir!(), "kazi_a11y_live_#{System.unique_integer([:positive])}")

      File.mkdir_p!(docroot)
      on_exit(fn -> File.rm_rf!(docroot) end)
      {:ok, docroot: docroot, port: serve(docroot)}
    end
  end

  @tag :browser_live
  test "a page with a real accessibility violation fails, scored + with evidence", context do
    if skipped?(context) do
      :ok
    else
      %{docroot: docroot, port: port} = context

      # An <img> with no alt text is a `serious`/`critical` axe violation
      # (image-alt), so it is caught at the default `serious` severity.
      write(docroot, "bad.html", """
      <!doctype html><html lang="en"><head><title>Shop</title></head><body>
        <h1>Shop</h1>
        <img src="/logo.png">
      </body></html>
      """)

      result =
        drive(docroot, "http://127.0.0.1:#{port}/bad.html", %{
          assertions: [%{type: "a11y", max_violations: 0}]
        })

      assert %PredicateResult{status: :fail, direction: :lower_better} = result
      assert result.score >= 1.0
      assert [a11y] = result.evidence.assertions
      refute a11y["ok"]
      assert a11y["count"] >= 1
      assert Enum.all?(a11y["found"], &(is_binary(&1["id"]) and is_list(&1["nodes"])))
    end
  end

  @tag :browser_live
  test "an accessible page passes with a zero-violation score", context do
    if skipped?(context) do
      :ok
    else
      %{docroot: docroot, port: port} = context

      write(docroot, "good.html", """
      <!doctype html><html lang="en"><head><title>Shop</title></head><body>
        <h1>Shop</h1>
        <img src="/logo.png" alt="Shop logo">
      </body></html>
      """)

      result =
        drive(docroot, "http://127.0.0.1:#{port}/good.html", %{
          assertions: [%{type: "a11y", severity: "serious", max_violations: 0}]
        })

      assert %PredicateResult{status: :pass, direction: :lower_better} = result
      assert result.score == 0.0
    end
  end

  # --- helpers ---------------------------------------------------------------

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
        server_name: ~c"kazi_a11y_live",
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
        "\n  [skipped] node + playwright + axe-core unavailable — the real runner was NOT exercised"
      )

      true
    else
      false
    end
  end

  defp deps_available? do
    case System.cmd(
           "node",
           ["-e", "require.resolve('playwright'); require.resolve('axe-core')"],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end
end
