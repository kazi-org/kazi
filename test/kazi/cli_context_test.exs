defmodule Kazi.CLIContextTest do
  @moduledoc """
  T35.7 (ADR-0045): the `kazi context index|search|stats` wrapper CLI — a THIN
  proxy over the `Kazi.ContextStore` provider behaviour so users learn ONE CLI
  while the provider (the `gist` binary) stays independently usable.

  Tier 1 pins the argv boundary: each subcommand parses into the
  `{:context, sub, args, opts}` tuple carrying `--provider` / `--budget` /
  `--json`; a missing or unknown subcommand is a clear usage error.

  Tier 2 drives the REAL CLI exec core (`Kazi.CLI.run/2`) through
  `ExUnit.CaptureIO`, with the `:context_store_opts` inject seam pointing the
  provider at the file-backed fake `gist` (`test/support/fake_gist.sh`, the same
  fixture `Kazi.ContextStore.GistCLITest` uses). The KEY properties:

    * `index`/`search`/`stats` PROXY to the provider (an index on one call is
      searchable on the next; stats accumulate) — the wrapper re-derives no
      provider logic;
    * under `--json` the WHOLE of stdout is a single PARSEABLE object (no human
      prose interleaved), with a stable exit code;
    * the human surface (the default) is unchanged-by-`--json` prose.

  No real `gist`, network, or read-model — the fake is a real external binary
  exercising the genuine subprocess + parse path end to end.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.CLI

  @fake Path.expand("../support/fake_gist.sh", __DIR__)

  setup do
    store = Path.join(System.tmp_dir!(), "cli-context-#{System.unique_integer([:positive])}")
    File.mkdir_p!(store)
    on_exit(fn -> File.rm_rf(store) end)

    # The inject seam (production passes none): point the provider at the
    # file-backed fake so the cross-call contract is exercised with no network.
    inject = [context_store_opts: [gist_bin: @fake, env: [{"FAKE_GIST_STORE", store}]]]
    {:ok, store: store, inject: inject}
  end

  # Capture stdout AND the exit code of a `Kazi.CLI.run/2` invocation.
  defp run_capture(argv, inject) do
    code = :erlang.make_ref()
    Process.put(code, nil)
    out = capture_io(fn -> Process.put(code, CLI.run(argv, inject)) end)
    {Process.get(code), out}
  end

  # Index a file under a label so a subsequent search/stats has something to hit.
  defp index_fixture(inject, store, label, content) do
    file = Path.join(store, "artifact-#{System.unique_integer([:positive])}.md")
    File.write!(file, content)
    {code, _} = run_capture(["context", "index", label, file], inject)
    assert code == 0
    file
  end

  # ===========================================================================
  # Tier 1 — the argv boundary
  # ===========================================================================

  describe "parse/1 — the context command boundary" do
    test "each subcommand parses into the context tuple with its args + flags" do
      assert {:context, "stats", [], opts} = CLI.parse(["context", "stats"])
      assert opts[:provider] == "gist"
      assert opts[:json] == false

      assert {:context, "search", ["needle"], sopts} =
               CLI.parse(["context", "search", "needle", "--budget", "4000", "--json"])

      assert sopts[:budget] == 4000
      assert sopts[:json] == true

      assert {:context, "index", ["lbl", "f.md"], iopts} =
               CLI.parse(["context", "index", "lbl", "f.md", "--provider", "gist"])

      assert iopts[:provider] == "gist"
    end

    test "a missing subcommand is a usage error (not an unknown-command hint)" do
      assert {:error, message} = CLI.parse(["context"])
      assert message =~ "requires a <subcommand>"
      assert message =~ "index"
    end

    test "an unknown subcommand is a clear error" do
      assert {:error, message} = CLI.parse(["context", "frobnicate"])
      assert message =~ "unknown context subcommand"
    end
  end

  # ===========================================================================
  # Tier 2 — the subcommands proxy to the provider (human surface)
  # ===========================================================================

  describe "index/search/stats proxy to the provider" do
    test "index reports the label + byte count", %{store: store, inject: inject} do
      content = "The login flow validates the token then issues a session cookie."
      file = Path.join(store, "doc.md")
      File.write!(file, content)

      {code, out} = run_capture(["context", "index", "kazi:doc:1", file], inject)
      assert code == 0
      assert out =~ "indexed kazi:doc:1"
      assert out =~ "#{byte_size(content)} B"
    end

    test "search after index returns the budget-fitting snippet", %{store: store, inject: inject} do
      index_fixture(inject, store, "kazi:doc:1", "validate the token then issue a session cookie")

      {code, out} = run_capture(["context", "search", "token session"], inject)
      assert code == 0
      assert out =~ "snippet"
      assert out =~ "token"
    end

    test "search honors --budget (never exceeds it)", %{store: store, inject: inject} do
      index_fixture(inject, store, "kazi:doc:big", String.duplicate("alpha beta gamma ", 100))

      {code, out} =
        run_capture(["context", "search", "alpha", "--budget", "32", "--json"], inject)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))

      for snippet <- payload["snippets"] do
        assert snippet["bytes"] <= 32
      end
    end

    test "stats reports the accumulated byte accounting", %{store: store, inject: inject} do
      content = "the token session cookie line"
      index_fixture(inject, store, "kazi:doc:1", content)
      {_, _} = run_capture(["context", "search", "token"], inject)

      {code, out} = run_capture(["context", "stats"], inject)
      assert code == 0
      assert out =~ "provider=gist"
      assert out =~ "indexed=#{byte_size(content)} B"
    end
  end

  # ===========================================================================
  # Tier 2 — --json is a single parseable object, stable exit
  # ===========================================================================

  describe "--json output is parseable (JSON-only stdout)" do
    test "stats --json decodes to one object with the byte accounting", %{
      store: store,
      inject: inject
    } do
      content = "token session cookie"
      index_fixture(inject, store, "kazi:doc:1", content)

      {code, out} = run_capture(["context", "stats", "--json"], inject)
      assert code == 0

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["command"] == "context"
      assert payload["subcommand"] == "stats"
      assert payload["provider"] == "gist"
      assert payload["indexed_bytes"] == byte_size(content)
      assert is_integer(payload["returned_bytes"])
      assert payload["saved_bytes"] == payload["indexed_bytes"] - payload["returned_bytes"]
      assert is_integer(payload["schema_version"])
    end

    test "index --json carries the label + bytes", %{store: store, inject: inject} do
      content = "a heavy artifact body"
      file = Path.join(store, "doc.md")
      File.write!(file, content)

      {code, out} = run_capture(["context", "index", "kazi:doc:1", file, "--json"], inject)
      assert code == 0

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["subcommand"] == "index"
      assert payload["label"] == "kazi:doc:1"
      assert payload["bytes"] == byte_size(content)
    end

    test "search --json carries the snippet list + budget", %{store: store, inject: inject} do
      index_fixture(inject, store, "kazi:doc:1", "validate the token then issue a session cookie")

      {code, out} =
        run_capture(["context", "search", "token", "--budget", "200", "--json"], inject)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["subcommand"] == "search"
      assert payload["query"] == "token"
      assert payload["budget"] == 200
      assert payload["count"] == length(payload["snippets"])
      assert Enum.all?(payload["snippets"], &is_binary(&1["text"]))
    end

    test "a miss is a clean empty result (exit 0)", %{store: store, inject: inject} do
      index_fixture(inject, store, "kazi:doc:1", "only this content")

      {code, out} =
        run_capture(["context", "search", "nonexistent-term-zzz", "--json"], inject)

      assert code == 0
      assert {:ok, %{"count" => 0, "snippets" => []}} = Jason.decode(String.trim(out))
    end
  end

  # ===========================================================================
  # Tier 2 — error surfaces (stable non-zero exit; JSON error under --json)
  # ===========================================================================

  describe "error handling" do
    test "an unknown provider errors on a stable non-zero exit", %{inject: inject} do
      {code, out} =
        run_capture(["context", "stats", "--provider", "nope", "--json"], inject)

      assert code == 1
      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "unknown context provider"
    end

    test "indexing a missing file is a clear error", %{inject: inject} do
      {code, out} =
        run_capture(["context", "index", "lbl", "/no/such/file.md", "--json"], inject)

      assert code == 1
      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "could not read"
    end

    test "an unavailable provider binary degrades to a clear error (no crash)" do
      inject = [context_store_opts: [gist_bin: "/no/such/dir/gist"]]
      {code, out} = run_capture(["context", "stats", "--json"], inject)

      assert code == 1
      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "not on PATH"
    end

    test "search without a query is a usage error", %{inject: inject} do
      stderr = capture_io(:stderr, fn -> assert CLI.run(["context", "search"], inject) == 1 end)
      assert stderr =~ "requires a <query>"
    end
  end
end
