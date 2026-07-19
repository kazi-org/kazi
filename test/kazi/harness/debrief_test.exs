defmodule Kazi.Harness.DebriefTest do
  @moduledoc """
  T48.11 (ADR-0058 §3): direct, pure coverage of the SELF-REPORT debrief tier —
  `question/0`'s fixed text, `extract/1`'s tolerant fenced-JSON parse, and the
  hard caps (`max_items/0`/`max_item_bytes/0`) enforced regardless of what the
  model returned. Also pins the WRITE-ONLY invariant: nothing in this module
  depends on the read-model.
  """
  use ExUnit.Case, async: true

  alias Kazi.Harness.Debrief

  describe "question/0" do
    test "is fixed text carrying the item/byte caps and the fenced-JSON shape" do
      q = Debrief.question()

      assert q =~ "#{Debrief.max_items()}"
      assert q =~ "#{Debrief.max_item_bytes()}"
      assert q =~ "```json"
      assert q =~ "needed_but_discovered"
    end

    test "is byte-identical across calls (a stable, cacheable prefix section)" do
      assert Debrief.question() == Debrief.question()
    end
  end

  describe "extract/1" do
    test "parses a well-formed fenced debrief block" do
      text = """
      Done fixing the predicates.

      ```json
      {"debrief": {"needed_but_discovered": ["lib/foo.ex has the config schema", "bar convention"]}}
      ```
      """

      assert Debrief.extract(text) == [
               "lib/foo.ex has the config schema",
               "bar convention"
             ]
    end

    test "returns [] when there is no fenced block" do
      assert Debrief.extract("just a plain reply, no debrief here") == []
    end

    test "returns [] for malformed JSON inside the fence" do
      text = "```json\n{not valid json\n```"
      assert Debrief.extract(text) == []
    end

    test "returns [] when the fenced JSON has the wrong shape" do
      text = ~s(```json\n{"something_else": true}\n```)
      assert Debrief.extract(text) == []
    end

    test "returns [] for a non-list needed_but_discovered" do
      text = ~s(```json\n{"debrief": {"needed_but_discovered": "not a list"}}\n```)
      assert Debrief.extract(text) == []
    end

    test "filters out non-string items in the list" do
      text = ~s(```json\n{"debrief": {"needed_but_discovered": ["ok", 1, null, "also ok"]}}\n```)
      assert Debrief.extract(text) == ["ok", "also ok"]
    end

    test "extracts the LAST fenced json block when the reply has more than one" do
      text = """
      ```json
      {"not": "the debrief block"}
      ```

      ```json
      {"debrief": {"needed_but_discovered": ["the real one"]}}
      ```
      """

      assert Debrief.extract(text) == ["the real one"]
    end

    test "handles nested objects/arrays inside the fenced block without truncating early" do
      text = ~s(```json
      {"debrief": {"needed_but_discovered": ["a"], "extra": {"nested": {"deep": [1, 2, 3]}}}}
      ```)

      assert Debrief.extract(text) == ["a"]
    end

    test "caps to max_items/0 regardless of how many the model reports" do
      items = for n <- 1..25, do: "item #{n}"
      text = ~s(```json\n#{Jason.encode!(%{debrief: %{needed_but_discovered: items}})}\n```)

      result = Debrief.extract(text)
      assert length(result) == Debrief.max_items()
      assert result == Enum.take(items, Debrief.max_items())
    end

    test "caps each item to max_item_bytes/0 regardless of how long the model's item was" do
      long_item = String.duplicate("x", Debrief.max_item_bytes() * 3)
      text = ~s(```json\n#{Jason.encode!(%{debrief: %{needed_but_discovered: [long_item]}})}\n```)

      [capped] = Debrief.extract(text)
      assert byte_size(capped) <= Debrief.max_item_bytes()
    end

    test "byte-caps without splitting a multi-byte UTF-8 codepoint in half" do
      # "a" (1 byte) shifts every subsequent 2-byte "é" onto an odd byte offset,
      # so the byte-500 cut boundary lands exactly on the FIRST byte of an "é" —
      # a genuine mid-codepoint split, not a coincidental character boundary.
      item = "a" <> String.duplicate("é", 300)
      text = ~s(```json\n#{Jason.encode!(%{debrief: %{needed_but_discovered: [item]}})}\n```)

      [capped] = Debrief.extract(text)
      assert byte_size(capped) <= Debrief.max_item_bytes()
      assert String.valid?(capped)
    end

    test "nil/non-binary input returns []" do
      assert Debrief.extract(nil) == []
    end
  end

  describe "extract_from_result/1 (the dispatch-result seam)" do
    test "reads the :result field of an {:ok, envelope} tuple" do
      result =
        {:ok, %{result: ~s(```json\n{"debrief": {"needed_but_discovered": ["x"]}}\n```)}}

      assert Debrief.extract_from_result(result) == ["x"]
    end

    test "falls back to :output when :result is absent" do
      result = %{output: ~s(```json\n{"debrief": {"needed_but_discovered": ["y"]}}\n```)}
      assert Debrief.extract_from_result(result) == ["y"]
    end

    test "an {:error, _} result yields []" do
      assert Debrief.extract_from_result({:error, :boom}) == []
    end

    test "a plain map with neither :result nor :output yields []" do
      assert Debrief.extract_from_result(%{exit: 0}) == []
    end

    test "an unrecognized shape yields [] rather than raising" do
      assert Debrief.extract_from_result("not even a map") == []
      assert Debrief.extract_from_result(nil) == []
    end
  end

  describe "write-only invariant (ADR-0058 §3, cf. T32.5)" do
    test "the module has no functional dependency on the read-model / hypothesis store" do
      source = File.read!(Path.join(["lib", "kazi", "harness", "debrief.ex"]))
      # Checks for actual code references (alias/call), not the moduledoc's
      # prose explaining the invariant (which legitimately names the schema).
      refute source =~ "alias Kazi.ReadModel"
      refute source =~ "Repo."
      refute source =~ "record_debrief_hypotheses"
      refute source =~ "list_debrief_hypotheses"
    end
  end
end
