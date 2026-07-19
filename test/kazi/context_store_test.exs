defmodule Kazi.ContextStoreTest do
  # async: false — `resolve/1`'s config-fallback path mutates Application env.
  use ExUnit.Case, async: false

  alias Kazi.ContextStore
  alias Kazi.ContextStore.{NoOp, Snippet}

  doctest Kazi.ContextStore

  # A recording test double: search returns a fixed snippet list carried in opts,
  # so resolution + dispatch can be asserted with no external `gist`.
  defmodule StaticStore do
    @behaviour Kazi.ContextStore

    @impl true
    def index(label, content, _opts),
      do: {:ok, %{label: label, bytes: byte_size(content), checksum: "fixed"}}

    @impl true
    def search(_query, _budget, opts), do: {:ok, Keyword.get(opts, :snippets, [])}

    @impl true
    def stats(opts),
      do:
        {:ok,
         %{
           provider: :static,
           indexed_bytes: Keyword.get(opts, :indexed, 0),
           returned_bytes: 0,
           saved_bytes: Keyword.get(opts, :indexed, 0)
         }}
  end

  setup do
    # Ensure each test starts with no configured store (off by default).
    prior = Application.get_env(:kazi, :context_store)
    Application.delete_env(:kazi, :context_store)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:kazi, :context_store, prior),
        else: Application.delete_env(:kazi, :context_store)
    end)

    :ok
  end

  describe "the no-op default (store OFF)" do
    test "resolve/1 with no opt and no config is the no-op backend" do
      assert {NoOp, []} = ContextStore.resolve([])
    end

    test "search/3 with no store returns {:ok, []} (the off state)" do
      assert ContextStore.search("anything", 6000) == {:ok, []}
    end

    test "index/3 with no store reports the label + bytes but stores nothing" do
      assert {:ok, %{label: "kazi:run:g1:iter:1:test-log", bytes: 5, checksum: nil}} =
               ContextStore.index("kazi:run:g1:iter:1:test-log", "hello")
    end

    test "stats/1 with no store reports zeroed accounting" do
      assert {:ok, %{provider: :none, indexed_bytes: 0, returned_bytes: 0, saved_bytes: 0}} =
               ContextStore.stats([])
    end
  end

  describe "resolution order (explicit opt > config > no-op)" do
    test "an explicit :context_store opt wins over config" do
      Application.put_env(:kazi, :context_store, NoOp)

      assert {StaticStore, [budget: 6000]} =
               ContextStore.resolve(context_store: {StaticStore, [budget: 6000]})
    end

    test "config is used when no explicit opt is given" do
      Application.put_env(:kazi, :context_store, StaticStore)
      assert {StaticStore, []} = ContextStore.resolve([])
    end

    test "a bare module normalises to a {module, []} tuple" do
      assert {StaticStore, []} = ContextStore.resolve(context_store: StaticStore)
    end
  end

  describe "dispatch through an injected store" do
    @snippet Snippet.new("indexed log line", source: "kazi:run:g1:iter:3:test-log")

    test "search/3 forwards the budget and returns the backend's snippets" do
      assert {:ok, [@snippet]} =
               ContextStore.search("error", 6000,
                 context_store: {StaticStore, [snippets: [@snippet]]}
               )
    end

    test "index/3 forwards content to the backend" do
      assert {:ok, %{label: "lbl", bytes: 3, checksum: "fixed"}} =
               ContextStore.index("lbl", "abc", context_store: StaticStore)
    end

    test "stats/1 forwards init opts to the backend" do
      assert {:ok, %{provider: :static, indexed_bytes: 754_257, saved_bytes: 754_257}} =
               ContextStore.stats(context_store: {StaticStore, [indexed: 754_257]})
    end
  end

  describe "Snippet round-trip" do
    test "to_serializable/1 then from_serializable/1 reconstructs an equal struct" do
      s = Snippet.new("body", source: "lbl", bytes: 4)
      assert s |> Snippet.to_serializable() |> Snippet.from_serializable() == s
    end
  end
end
