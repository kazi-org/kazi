defmodule Kazi.RetrievalTest do
  # async: false — `resolve/1`'s config-fallback path mutates Application env.
  use ExUnit.Case, async: false

  alias Kazi.PredicateResult
  alias Kazi.Retrieval
  alias Kazi.Retrieval.{NoOp, Snippet, StaticRetriever}

  @failing [{:unit, PredicateResult.fail(%{output: "boom"})}]
  @workspace "/fixture/ws"

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
  end
end
