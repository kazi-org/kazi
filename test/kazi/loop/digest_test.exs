defmodule Kazi.Loop.DigestTest do
  use ExUnit.Case, async: true

  doctest Kazi.Loop.Digest

  alias Kazi.Loop.Digest

  # ===========================================================================
  # from_result/2 — map memory ONLY (the crux: never the transcript)
  # ===========================================================================

  describe "from_result/2 reads the working set" do
    test "distills the touched file paths from a success envelope" do
      result = {:ok, %{touched: ["lib/a.ex", "lib/b.ex"], result: "ignored", output: "ignored"}}

      assert %Digest{files: ["lib/a.ex", "lib/b.ex"], dropped: 0} = Digest.from_result(result)
    end

    test "normalises: drops non-strings/blanks, trims, de-dupes preserving order" do
      result =
        {:ok, %{touched: ["  lib/a.ex  ", "lib/a.ex", "", 42, nil, "lib/b.ex"]}}

      assert %Digest{files: ["lib/a.ex", "lib/b.ex"], dropped: 0} = Digest.from_result(result)
    end

    test "caps the working set to :max_files, counting the overflow in :dropped" do
      files = for i <- 1..30, do: "lib/f#{i}.ex"

      assert %Digest{files: kept, dropped: 25} =
               Digest.from_result({:ok, %{touched: files}}, max_files: 5)

      assert kept == ["lib/f1.ex", "lib/f2.ex", "lib/f3.ex", "lib/f4.ex", "lib/f5.ex"]
    end

    test "a non-positive cap yields the empty digest" do
      assert Digest.from_result({:ok, %{touched: ["lib/a.ex"]}}, max_files: 0) == Digest.empty()
    end
  end

  describe "from_result/2 carries NO conversation memory" do
    # The anti-anchoring guarantee (ADR-0008): the digest is built ONLY from the
    # touched set, never the agent's transcript/reasoning/result text. These cases
    # pin that structurally — a result carrying ONLY transcript-shaped fields must
    # produce the empty digest, and a transcript present ALONGSIDE a touched set
    # must not leak into the files.
    test "a result with only transcript fields (no :touched) yields the empty digest" do
      transcript_only =
        {:ok,
         %{
           result: "I tried refactoring the parser, then reverted and patched the lexer instead.",
           output: ~s({"result":"long agent transcript with reasoning..."})
         }}

      assert Digest.from_result(transcript_only) == Digest.empty()
    end

    test "transcript fields present alongside :touched never appear in the digest" do
      secret = "I attempted approach X and it failed because of Y"

      result =
        {:ok,
         %{
           touched: ["lib/a.ex"],
           result: secret,
           output: secret,
           reasoning: secret
         }}

      digest = Digest.from_result(result)

      assert digest.files == ["lib/a.ex"]
      refute Enum.any?(digest.files, &(&1 =~ "approach X"))
      # And it never reaches the render either.
      rendered = Digest.render(digest)
      refute rendered =~ "approach X"
      refute rendered =~ "failed because"
    end

    test "an error result yields the empty digest" do
      assert Digest.from_result({:error, :boom}) == Digest.empty()
      assert Digest.from_result({:error, {:command_not_found, "claude"}}) == Digest.empty()
    end

    test "a success envelope without a :touched list yields the empty digest" do
      assert Digest.from_result({:ok, %{output: "ok", cost: %{tokens: 1}}}) == Digest.empty()
      # A non-list :touched is ignored (defensive against a surprising envelope).
      assert Digest.from_result({:ok, %{touched: "lib/a.ex"}}) == Digest.empty()
    end
  end

  # ===========================================================================
  # render/2 — compact, bounded, files-only note
  # ===========================================================================

  describe "render/2" do
    test "the empty digest renders to the empty string (first-iteration back-compat)" do
      assert Digest.render(Digest.empty()) == ""
    end

    test "renders a files-touched bullet list with a map-memory header" do
      digest = Digest.from_result({:ok, %{touched: ["lib/a.ex", "lib/b.ex"]}})
      note = Digest.render(digest)

      assert note =~ "Working set"
      assert note =~ "map memory"
      assert note =~ "- lib/a.ex"
      assert note =~ "- lib/b.ex"
      # It points the agent back at the live failing evidence as the source of
      # truth — orientation, not instruction.
      assert note =~ "source of truth"
    end

    test "surfaces the dropped overflow as a (+N more) line" do
      files = for i <- 1..10, do: "lib/f#{i}.ex"
      digest = Digest.from_result({:ok, %{touched: files}}, max_files: 3)

      note = Digest.render(digest)
      assert note =~ "- lib/f1.ex"
      assert note =~ "(+7 more)"
    end

    test "bounds the rendered section to :max_bytes, folding dropped paths into the count" do
      files = for i <- 1..50, do: "lib/some/long/path/module_number_#{i}.ex"
      digest = Digest.from_result({:ok, %{touched: files}}, max_files: 50)

      # A budget above the fixed header floor but well under all 50 paths: the
      # render must drop paths from the tail (into `(+N more)`) to fit.
      note = Digest.render(digest, max_bytes: 400)

      assert byte_size(note) <= 400
      # Bytes were reclaimed by dropping paths from the tail into (+N more).
      assert note =~ "more)"
      # At least the first path survived (never degrades to a bare header).
      assert note =~ "module_number_1.ex"
      # The far-tail paths were the ones dropped to fit.
      refute note =~ "module_number_50.ex"
    end

    test "honours the byte budget even when a single path overflows it (no bare header)" do
      # The header alone is fixed overhead; with a budget below header+one-path the
      # render keeps the first path anyway rather than degrading to a bare header.
      digest = Digest.from_result({:ok, %{touched: ["lib/a.ex", "lib/b.ex"]}})

      note = Digest.render(digest, max_bytes: 1)

      assert note =~ "lib/a.ex"
      assert note =~ "Working set"
    end

    test "an empty digest still renders empty even with a byte budget" do
      assert Digest.render(Digest.empty(), max_bytes: 10) == ""
    end
  end

  # ===========================================================================
  # from_files/2 + empty?/1
  # ===========================================================================

  describe "from_files/2 and empty?/1" do
    test "builds a bounded digest directly from a path list" do
      assert %Digest{files: ["a", "b"], dropped: 1} = Digest.from_files(["a", "b", "c"], 2)
    end

    test "garbage input yields the empty digest" do
      assert Digest.from_files(:not_a_list, 5) == Digest.empty()
      assert Digest.from_files([], 5) == Digest.empty()
    end

    test "empty?/1 distinguishes the empty digest from a populated one" do
      assert Digest.empty?(Digest.empty())
      refute Digest.empty?(Digest.from_files(["a"], 5))
    end
  end
end
