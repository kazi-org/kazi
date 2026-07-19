defmodule Kazi.Providers.BrowserConsoleCleanLiveTest do
  # The REAL runner, driving a REAL Chromium over a REAL journey (T43.1,
  # ADR-0053 §1, UC-056). Everything else in the browser suite injects the stub
  # runner, which proves the provider's mapping but can never prove the runner
  # actually CAPTURES anything — the console listener, its journey-wide scope, and
  # the 4xx/5xx branch are all Playwright behaviour that only a real browser
  # exercises. This is that proof.
  #
  # Tagged `:browser_live` and EXCLUDED by default so `mix test` and CI stay
  # hermetic (no Playwright, no browser download). Opt in explicitly:
  #
  #     mix test --only browser_live test/kazi/providers/browser_console_clean_live_test.exs
  #
  # Requires the runner's own dep, installed once at the repo root:
  #
  #     npm i playwright && npx playwright install chromium
  #
  # The test probes for node + playwright first and SKIPS HONESTLY when either is
  # missing — it never fails and never fake-passes on a machine without a browser.
  use ExUnit.Case, async: false

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Browser

  @moduletag :browser_live
  # A real Chromium launch + navigation is far slower than ExUnit's 60s default.
  @moduletag timeout: 180_000

  @runner Path.expand("../../../priv/browser/playwright_runner.js", __DIR__)

  setup_all do
    if playwright_available?() do
      :ok
    else
      {:ok, skip: true}
    end
  end

  setup context do
    if context[:skip] do
      # An honest skip: no browser here, so this proves nothing either way.
      :ok
    else
      docroot = Path.join(System.tmp_dir!(), "kazi_console_#{System.unique_integer([:positive])}")
      File.mkdir_p!(docroot)
      on_exit(fn -> File.rm_rf!(docroot) end)
      {:ok, docroot: docroot, port: serve(docroot)}
    end
  end

  @tag :browser_live
  test "the real runner records console errors raised across the journey", context do
    skip_unless_browser(context)
    %{docroot: docroot, port: port} = context

    # Errors on the INITIAL LOAD and from a later STEP: `console_clean` asserts
    # over the whole journey, so both must land in the record.
    write(docroot, "index.html", """
    <!doctype html><html><body>
      <h1>Shop</h1>
      <button id="cart" onclick="console.error('cart exploded: undefined is not an object')">
        Cart
      </button>
      <script>console.error("boom on load");</script>
    </body></html>
    """)

    result =
      drive(docroot, "http://127.0.0.1:#{port}/index.html", %{
        steps: [%{action: "click", selector: "#cart"}],
        assertions: [%{type: "console_clean"}]
      })

    # A console error the page really produced is failing UI work, not infra.
    assert %PredicateResult{status: :fail} = result
    assert [assertion] = result.evidence.assertions
    assert assertion["type"] == "console_clean"
    refute assertion["ok"]
    assert assertion["expected"] == 0

    texts = Enum.map(assertion["found"], & &1["text"])
    assert length(texts) == 2, "expected the load AND the step error, got: #{inspect(texts)}"
    assert Enum.any?(texts, &(&1 =~ "boom on load"))
    assert Enum.any?(texts, &(&1 =~ "cart exploded")), "a mid-journey error must be captured"
    assert Enum.all?(assertion["found"], &(&1["kind"] == "console.error"))
  end

  @tag :browser_live
  test "a genuinely clean journey passes", context do
    skip_unless_browser(context)
    %{docroot: docroot, port: port} = context

    write(docroot, "clean.html", """
    <!doctype html><html><body>
      <h1>Shop</h1>
      <button id="cart" onclick="console.log('cart opened')">Cart</button>
    </body></html>
    """)

    result =
      drive(docroot, "http://127.0.0.1:#{port}/clean.html", %{
        steps: [%{action: "click", selector: "#cart"}],
        assertions: [%{type: "console_clean", network: true}, %{type: "visible", selector: "h1"}]
      })

    assert %PredicateResult{status: :pass} = result
    assert [console, _visible] = result.evidence.assertions
    # console.log is NOT console.error — only errors trip the assertion.
    assert console["found"] == []
  end

  @tag :browser_live
  test "network: true adds a structured 4xx/5xx record to the evidence", context do
    skip_unless_browser(context)
    %{docroot: docroot, port: port} = context

    write(docroot, "broken.html", """
    <!doctype html><html><body>
      <h1>Shop</h1>
      <img src="/no-such-image.png">
    </body></html>
    """)

    url = "http://127.0.0.1:#{port}/broken.html"

    # Chromium logs its OWN console.error for a failed subresource ("Failed to
    # load resource: ... 404"), so a 4xx already trips console_clean without
    # `network` — verified against a real Chromium, not assumed. `network: true`
    # is therefore not about catching MORE failures in this shape; it is about the
    # EVIDENCE. Chromium's message is prose with no parseable status, while a
    # network record carries `status` as an integer and `url` as a field, which is
    # what a fixer agent can actually act on.
    without = drive(docroot, url, %{assertions: [%{type: "console_clean"}]})

    assert %PredicateResult{status: :fail} = without
    assert [%{"found" => console_only}] = without.evidence.assertions
    assert Enum.all?(console_only, &(&1["kind"] == "console.error"))

    refute Enum.any?(console_only, &(&1["kind"] == "network")),
           "without `network` the record must hold no network entries"

    result = drive(docroot, url, %{assertions: [%{type: "console_clean", network: true}]})

    assert %PredicateResult{status: :fail} = result
    assert [assertion] = result.evidence.assertions
    refute assertion["ok"]
    assert [failure] = Enum.filter(assertion["found"], &(&1["kind"] == "network"))
    assert failure["status"] == 404
    assert failure["url"] =~ "no-such-image.png"
  end

  # --- helpers ---------------------------------------------------------------

  defp drive(docroot, url, config) do
    Browser.evaluate(
      Predicate.new(:ui, :browser, config: Map.merge(%{url: url, args: [@runner]}, config)),
      %{workspace: docroot}
    )
  end

  defp write(docroot, name, body), do: File.write!(Path.join(docroot, name), body)

  # OTP's stdlib httpd: a real HTTP origin (so a missing file is a real 404,
  # which `file://` can never produce) with no extra dependency.
  defp serve(docroot) do
    {:ok, _} = :application.ensure_all_started(:inets)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        server_name: ~c"kazi_console_clean",
        server_root: String.to_charlist(docroot),
        document_root: String.to_charlist(docroot),
        bind_address: ~c"127.0.0.1"
      )

    on_exit(fn -> :inets.stop(:httpd, pid) end)
    :proplists.get_value(:port, :httpd.info(pid))
  end

  defp skip_unless_browser(context) do
    if context[:skip] do
      # Honest skip, not a silent pass: say so and stop.
      IO.puts("\n  [skipped] node + playwright unavailable — the real runner was NOT exercised")
      :ok
    end
  end

  defp playwright_available? do
    case System.cmd("node", ["-e", "require.resolve('playwright')"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    # node itself absent.
    ErlangError -> false
  end
end
