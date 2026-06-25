defmodule Kazi.ContextStore.GistCLITest do
  use ExUnit.Case, async: true

  alias Kazi.ContextStore
  alias Kazi.ContextStore.{GistCLI, Labels, Snippet}

  @fake Path.expand("../../support/fake_gist.sh", __DIR__)

  setup do
    store = Path.join(System.tmp_dir!(), "fake-gist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(store)
    on_exit(fn -> File.rm_rf(store) end)
    # opts that point the adapter at the file-backed fake instead of real `gist`.
    {:ok, store: store, opts: [gist_bin: @fake, env: [{"FAKE_GIST_STORE", store}]]}
  end

  describe "the fake fixture is wired" do
    test "fake_gist.sh exists and is executable" do
      assert File.exists?(@fake)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(@fake)
      assert Bitwise.band(mode, 0o111) != 0
    end
  end

  describe "index then search (cross-call, file-backed)" do
    test "index returns the label + byte count + chunks", %{opts: opts} do
      label = Labels.run_test_log("g1", 1)
      content = "The login flow validates the token then issues a session cookie."

      assert {:ok, %{label: ^label, bytes: bytes, chunks: chunks}} =
               GistCLI.index(label, content, opts)

      assert bytes == byte_size(content)
      assert chunks == 1
    end

    test "search after index returns a budget-fitting snippet", %{opts: opts} do
      content = "The login flow validates the token then issues a session cookie."
      assert {:ok, _} = GistCLI.index(Labels.run_test_log("g1", 1), content, opts)

      assert {:ok, [%Snippet{} = snippet]} = GistCLI.search("token session", 200, opts)
      assert snippet.text =~ "token"
      assert snippet.bytes <= 200
      assert snippet.bytes == byte_size(snippet.text)
    end

    test "the returned snippet never exceeds the byte budget", %{opts: opts} do
      content = String.duplicate("alpha beta gamma delta ", 100)
      assert {:ok, _} = GistCLI.index(Labels.workspace_doc("sha1", "notes.md"), content, opts)

      assert {:ok, [snippet]} = GistCLI.search("alpha", 64, opts)
      assert snippet.bytes <= 64
    end

    test "a miss returns {:ok, []}", %{opts: opts} do
      assert {:ok, _} = GistCLI.index(Labels.run_test_log("g1", 1), "only this content", opts)
      assert {:ok, []} = GistCLI.search("nonexistent-term-zzz", 200, opts)
    end

    test "search with an empty store returns {:ok, []}", %{opts: opts} do
      assert {:ok, []} = GistCLI.search("anything", 200, opts)
    end
  end

  describe "stats accounting" do
    test "stats reports parsed byte counters with provider :gist", %{opts: opts} do
      content = "The login flow validates the token then issues a session cookie."
      assert {:ok, _} = GistCLI.index(Labels.run_test_log("g1", 1), content, opts)
      assert {:ok, [_]} = GistCLI.search("token", 200, opts)

      assert {:ok, stats} = GistCLI.stats(opts)
      assert stats.provider == :gist
      assert stats.indexed_bytes == byte_size(content)
      assert stats.returned_bytes > 0
      assert stats.saved_bytes == stats.indexed_bytes - stats.returned_bytes
    end

    test "an empty store reports zeroed accounting", %{opts: opts} do
      assert {:ok, %{provider: :gist, indexed_bytes: 0, returned_bytes: 0, saved_bytes: 0}} =
               GistCLI.stats(opts)
    end
  end

  describe "graceful degradation when gist is not available" do
    test "a missing path-form binary disables every callback (no crash)" do
      opts = [gist_bin: "/no/such/dir/gist"]
      assert {:error, :gist_not_available} = GistCLI.index("lbl", "x", opts)
      assert {:error, :gist_not_available} = GistCLI.search("q", 100, opts)
      assert {:error, :gist_not_available} = GistCLI.stats(opts)
    end

    test "a missing bare-name binary (not on PATH) disables the store" do
      opts = [gist_bin: "kazi-definitely-not-a-real-binary-xyz"]
      assert {:error, :gist_not_available} = GistCLI.search("q", 100, opts)
    end
  end

  describe "dispatch through the Kazi.ContextStore behaviour" do
    test "resolve + search/index/stats route to GistCLI via context_store opt", %{opts: opts} do
      store_opt = [context_store: {GistCLI, opts}]

      assert {GistCLI, ^opts} = ContextStore.resolve(store_opt)

      assert {:ok, _} =
               ContextStore.index(Labels.run_test_log("g1", 2), "token cookie", store_opt)

      assert {:ok, [%Snippet{}]} = ContextStore.search("token", 200, store_opt)
      assert {:ok, %{provider: :gist}} = ContextStore.stats(store_opt)
    end
  end
end
