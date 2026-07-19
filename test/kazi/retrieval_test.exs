defmodule Kazi.RetrievalTest do
  # async: false — `resolve/1`'s config-fallback path mutates Application env.
  use ExUnit.Case, async: false

  alias Kazi.PredicateResult
  alias Kazi.Retrieval
  alias Kazi.Retrieval.{CountingRetriever, InMemorySnippetCache, NoOp, Snippet, StaticRetriever}

  @failing [{:unit, PredicateResult.fail(%{output: "boom"})}]
  @workspace "/fixture/ws"
  @git_sha "abc123"
  @radius ["lib/a.ex", "lib/b.ex"]

  describe "the no-op default (retrieval OFF)" do
    test "resolve/1 with no opt and no config is the no-op backend" do
      assert {NoOp, []} = Retrieval.resolve([])
    end

    test "the no-op backend returns []" do
      assert NoOp.retrieve(@failing, @workspace, []) == []
    end

    test "retrieve/3 with no retriever returns [] (the off state)" do
      assert Retrieval.retrieve(@failing, @workspace, []) == []
    end
  end

  describe "resolution order (explicit opt > config > no-op)" do
    test "an explicit :retriever opt wins over config" do
      # Config set to a no-op tuple; the explicit opt must take precedence.
      Application.put_env(:kazi, :retriever, NoOp)
      on_exit(fn -> Application.delete_env(:kazi, :retriever) end)

      retriever = StaticRetriever.new(snippets: [{"hello", source: "lib/a.ex"}])

      assert {StaticRetriever, [snippets: [{"hello", source: "lib/a.ex"}]]} =
               Retrieval.resolve(retriever: retriever)
    end

    test "falls back to config when no opt is supplied" do
      Application.put_env(:kazi, :retriever, {StaticRetriever, snippets: ["from-config"]})
      on_exit(fn -> Application.delete_env(:kazi, :retriever) end)

      assert {StaticRetriever, [snippets: ["from-config"]]} = Retrieval.resolve([])

      # …and the configured backend actually runs through retrieve/3.
      assert [%Snippet{text: "from-config"}] = Retrieval.retrieve(@failing, @workspace, [])
    end

    test "a bare module retriever normalises to {module, []}" do
      assert {NoOp, []} = Retrieval.resolve(retriever: NoOp)
    end
  end

  describe "the injected stub retriever" do
    test "returns the configured snippets, coercing shorthands" do
      retriever =
        StaticRetriever.new(
          snippets: [
            {"def build(x), do: x + 1", source: "lib/a.ex:42"},
            "plain text",
            Snippet.new("ready-made", source: "lib/b.ex")
          ]
        )

      assert [
               %Snippet{text: "def build(x), do: x + 1", source: "lib/a.ex:42"},
               %Snippet{text: "plain text", source: nil},
               %Snippet{text: "ready-made", source: "lib/b.ex"}
             ] = Retrieval.retrieve(@failing, @workspace, retriever: retriever)
    end

    test "is deterministic — the same fixed retriever yields equal results" do
      retriever = StaticRetriever.new(snippets: [{"x", source: "lib/a.ex"}, "y"])

      first = Retrieval.retrieve(@failing, @workspace, retriever: retriever)
      second = Retrieval.retrieve(@failing, @workspace, retriever: retriever)

      assert first == second
    end
  end

  describe "Kazi.Retrieval.Snippet" do
    test "new/2 carries text and an optional source" do
      assert %Snippet{text: "t", source: "lib/a.ex"} = Snippet.new("t", source: "lib/a.ex")
      assert %Snippet{text: "t", source: nil} = Snippet.new("t")
    end

    test "to_serializable/1 + from_serializable/1 round-trip exactly" do
      for s <- [Snippet.new("body", source: "lib/a.ex:42"), Snippet.new("orphan")] do
        assert Snippet.from_serializable(Snippet.to_serializable(s)) == s
      end
    end
  end

  describe "cached_retrieve/4 (SHA-keyed cache reuse, T4.9c)" do
    setup do
      %{cache: InMemorySnippetCache.start()}
    end

    test "first call is a miss: it retrieves and caches the snippets", %{cache: cache} do
      retriever = CountingRetriever.new(snippets: [{"x", source: "lib/a.ex"}, "y"])

      snippets =
        Retrieval.cached_retrieve(@failing, @workspace, {@git_sha, @radius},
          cache: cache,
          retriever: retriever
        )

      assert [%Snippet{text: "x", source: "lib/a.ex"}, %Snippet{text: "y"}] = snippets
      assert CountingRetriever.count() == 1
    end

    test "a fresh hit reuses cached snippets WITHOUT re-invoking the retriever",
         %{cache: cache} do
      retriever = CountingRetriever.new(snippets: [{"x", source: "lib/a.ex"}])

      first =
        Retrieval.cached_retrieve(@failing, @workspace, {@git_sha, @radius},
          cache: cache,
          retriever: retriever
        )

      # Second call: same (workspace, git-sha, failing-set) AND same blast radius.
      # The retriever must NOT run again — the snippets come from the cache.
      second =
        Retrieval.cached_retrieve(@failing, @workspace, {@git_sha, @radius},
          cache: cache,
          retriever: retriever,
          on_retrieve: fn -> flunk("retriever re-invoked on a cache hit") end
        )

      assert second == first
      assert CountingRetriever.count() == 1
    end

    test "a changed blast radius invalidates the entry and re-retrieves", %{cache: cache} do
      retriever = CountingRetriever.new(snippets: ["s"])

      _first =
        Retrieval.cached_retrieve(@failing, @workspace, {@git_sha, @radius},
          cache: cache,
          retriever: retriever
        )

      # Same key, but the blast radius moved under us (a file changed): the cached
      # snippets are stale, so the retriever runs again.
      _second =
        Retrieval.cached_retrieve(@failing, @workspace, {@git_sha, ["lib/c.ex"]},
          cache: cache,
          retriever: retriever
        )

      assert CountingRetriever.count() == 2
    end

    test "a changed git-sha is a different key and re-retrieves", %{cache: cache} do
      retriever = CountingRetriever.new(snippets: ["s"])

      _first =
        Retrieval.cached_retrieve(@failing, @workspace, {@git_sha, @radius},
          cache: cache,
          retriever: retriever
        )

      _second =
        Retrieval.cached_retrieve(@failing, @workspace, {"deadbeef", @radius},
          cache: cache,
          retriever: retriever
        )

      assert CountingRetriever.count() == 2
    end

    test "with no retriever (off), cached_retrieve returns [] and caches the empty result",
         %{cache: cache} do
      assert [] =
               Retrieval.cached_retrieve(@failing, @workspace, {@git_sha, @radius}, cache: cache)

      # A second identical call is a hit on the cached empty result — still [].
      assert [] =
               Retrieval.cached_retrieve(@failing, @workspace, {@git_sha, @radius},
                 cache: cache,
                 on_retrieve: fn -> flunk("re-ran on a cached empty result") end
               )
    end
  end
end
