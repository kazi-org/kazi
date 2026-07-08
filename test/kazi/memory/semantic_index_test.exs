defmodule Kazi.Memory.SemanticIndexTest do
  @moduledoc """
  ADR-0062: budgeted FTS recall over a git-native corpus. Hermetic — a fixture
  corpus under a real tmp dir, a per-test Sandbox transaction, no network, no
  external process.
  """
  # SQLite has a single writer; the Sandbox shares one connection, so tests run
  # serially (mirrors Kazi.ReadModel.RetrievalSnippetCacheTest).
  use ExUnit.Case, async: false

  alias Kazi.Memory.SemanticIndex
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp fixture_dir do
    dir =
      Path.join(System.tmp_dir!(), "kazi-semantic-index-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "docs"))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_lore(dir, content) do
    path = Path.join(dir, "docs/lore.md")
    File.write!(path, content)
    path
  end

  @lore """
  # Lore

  ## Landmine: budget overflow
  Recall must never exceed the caller's token budget under any circumstance.

  ## Invariant: corpus is read-only
  kazi never writes back to the corpus markdown.
  """

  describe "chunk_markdown/1" do
    test "chunks at heading granularity with correct path-independent line spans" do
      chunks = SemanticIndex.chunk_markdown(@lore)

      assert [preamble, landmine, invariant] = chunks
      assert preamble.heading == "# Lore"
      assert preamble.line_start == 1

      assert landmine.heading == "## Landmine: budget overflow"
      assert landmine.text =~ "never exceed"
      assert landmine.line_start == 3
      assert landmine.line_end == 5

      assert invariant.heading == "## Invariant: corpus is read-only"
      assert invariant.line_start == 6
    end

    test "drops blank/whitespace-only chunks" do
      assert SemanticIndex.chunk_markdown("\n\n   \n") == []
    end

    test "content with no heading is one leading chunk" do
      assert [%{heading: "", text: "just prose"}] = SemanticIndex.chunk_markdown("just prose")
    end
  end

  describe "recall/3 — end to end over a fixture corpus" do
    test "indexes and recalls a matching chunk with its path:line attribution" do
      dir = fixture_dir()
      write_lore(dir, @lore)

      [snippet | _] =
        SemanticIndex.recall("budget overflow", 200, workspace: dir, corpus: ["docs/**/*.md"])

      assert snippet.path == "docs/lore.md"
      assert snippet.line == 3
      assert snippet.text =~ "never exceed"
      assert is_float(snippet.score)
    end

    test "a query with no matching term returns no snippets" do
      dir = fixture_dir()
      write_lore(dir, @lore)

      assert SemanticIndex.recall("nonexistent_term_xyz", 200,
               workspace: dir,
               corpus: ["docs/**/*.md"]
             ) ==
               []
    end
  end

  describe "recall/3 — the budget contract" do
    test "the returned slice never exceeds the char budget" do
      dir = fixture_dir()
      write_lore(dir, @lore)

      snippets =
        SemanticIndex.recall("budget corpus", 8, workspace: dir, corpus: ["docs/**/*.md"])

      total = snippets |> Enum.map(&byte_size(&1.text)) |> Enum.sum()

      # budget_tokens=8 * 4 chars/token = 32 chars max.
      assert total <= 32
    end

    test "the top-ranked chunk alone exceeding the budget is truncated, never overflowing" do
      dir = fixture_dir()
      write_lore(dir, @lore)

      # budget_tokens=1 -> 4 chars max; every real chunk is far larger than that.
      snippets =
        SemanticIndex.recall("budget overflow", 1, workspace: dir, corpus: ["docs/**/*.md"])

      assert [snippet] = snippets
      assert byte_size(snippet.text) <= 4
    end

    test "a zero budget recalls nothing" do
      dir = fixture_dir()
      write_lore(dir, @lore)

      assert SemanticIndex.recall("budget overflow", 0, workspace: dir, corpus: ["docs/**/*.md"]) ==
               []
    end
  end

  describe "recall/3 — empty corpus" do
    test "an explicitly empty corpus is valid and yields zero recall" do
      dir = fixture_dir()
      write_lore(dir, @lore)

      assert SemanticIndex.recall("budget", 200, workspace: dir, corpus: []) == []
    end

    test "a corpus whose globs match no file yields zero recall" do
      dir = fixture_dir()

      assert SemanticIndex.recall("budget", 200, workspace: dir, corpus: ["docs/**/*.md"]) == []
    end
  end

  describe "refresh/2 — content-hash incremental indexing" do
    test "an unchanged file is never re-indexed" do
      dir = fixture_dir()
      write_lore(dir, @lore)

      :ok = SemanticIndex.refresh(dir, ["docs/**/*.md"])

      {:ok, %{rows: [[rowid_before]]}} =
        Repo.query("SELECT rowid FROM memory_chunks_fts WHERE path = ? LIMIT 1", ["docs/lore.md"])

      :ok = SemanticIndex.refresh(dir, ["docs/**/*.md"])

      {:ok, %{rows: [[rowid_after]]}} =
        Repo.query("SELECT rowid FROM memory_chunks_fts WHERE path = ? LIMIT 1", ["docs/lore.md"])

      assert rowid_before == rowid_after
    end

    test "a changed file is re-chunked" do
      dir = fixture_dir()
      write_lore(dir, @lore)

      :ok = SemanticIndex.refresh(dir, ["docs/**/*.md"])
      write_lore(dir, @lore <> "\n## New section\nfresh content here.\n")
      :ok = SemanticIndex.refresh(dir, ["docs/**/*.md"])

      {:ok, %{rows: rows}} =
        Repo.query("SELECT body FROM memory_chunks_fts WHERE path = ?", ["docs/lore.md"])

      assert Enum.any?(rows, fn [body] -> body =~ "fresh content here" end)
    end
  end
end
