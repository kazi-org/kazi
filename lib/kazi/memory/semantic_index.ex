defmodule Kazi.Memory.SemanticIndex do
  @moduledoc """
  The semantic memory layer (ADR-0060 layer 3, ADR-0062): budgeted FTS
  recall over the git-native corpus.

  ## The store of record is repo markdown (decision 1)

  kazi never copies project knowledge into an opaque database. The
  `default_corpus/0` globs a handful of conventional files — ADRs, the lore
  and devlog, `AGENTS.md`/`CLAUDE.md`/`README.md` — and a goal may override
  the set entirely via its `[memory]` table's `corpus` key
  (`Kazi.Goal.Loader`). Deleting this module's SQLite index loses nothing but
  a rebuild: the files remain the truth.

  ## Index: SQLite FTS5, zero new dependencies (decision 2)

  Corpus files are chunked at heading/entry granularity (`chunk_markdown/1`)
  and stored in the `memory_chunks_fts` FTS5 virtual table, each chunk
  carrying its source `path` + `line_start`/`line_end`. `refresh/2`
  incrementally re-chunks only a file whose sha256 content hash (tracked in
  `Kazi.ReadModel.MemoryIndexFile`) has changed since the last refresh — an
  unchanged file is never re-indexed.

  ## Rows are scoped per workspace (issue #977)

  Both `memory_index_files` and `memory_chunks_fts` carry a `workspace_root` —
  `workspace` canonicalized via `Path.expand/1` — alongside `path`. Two
  workspaces sharing one read-model (`~/.kazi/kazi.db`) can each have a file
  at the same relative path (e.g. "CLAUDE.md"); scoping every read/write by
  `{workspace_root, path}` instead of `path` alone means those rows can never
  clobber or leak into each other's recall.

  ## The API is budgeted recall, not search (decision 3)

  `recall/3` is the one entry point: query terms in, a ranked slice out that
  is GUARANTEED to fit the caller's token budget (an approximate
  chars-per-token heuristic, like `Kazi.Memory.AttemptLedger`'s rendering
  cap). The top-ranked chunk alone exceeding the budget is truncated, never
  dropped-with-overflow. Every snippet carries `path`/`line` (its source) and
  a relevance `score`.

  ## Recall is read-only (decision 5)

  This module adds NO write path to the corpus — it only ever `File.read/1`s
  corpus files; every write here targets the SQLite read-model (the index),
  never the source markdown. Corpus files are eligible
  `[enforcement] read_only_paths` (ADR-0042) so a goal can pin its corpus
  read-only during a run.

  ## Chunking is markdown-heading granularity

  A chunk starts at each ATX heading line (`#`..`######`); a file's preamble
  (before its first heading) is its own leading chunk. Blank/whitespace-only
  chunks are dropped. This is deliberately simple — a curated corpus of
  ADRs/lore/devlog files is already heading-structured, so a coarser
  paragraph- or sentence-level chunker would just add noise, not precision.
  """

  alias Kazi.ReadModel.MemoryIndexFile
  alias Kazi.Repo

  @typedoc "One recalled snippet: its source (`path`/`line`), text, and relevance score."
  @type snippet :: %{path: String.t(), line: pos_integer(), text: String.t(), score: float()}

  @typedoc "One parsed markdown chunk, before it is persisted."
  @type chunk :: %{
          heading: String.t(),
          line_start: pos_integer(),
          line_end: pos_integer(),
          text: String.t()
        }

  # ADR-0062 decision 1: the default corpus, overridable per goal-file via
  # `[memory] corpus = [...]` (`Kazi.Goal.Loader`, `Goal.memory_corpus`).
  @default_corpus [
    "docs/adr/**/*.md",
    "docs/lore.md",
    "docs/devlog.md",
    "AGENTS.md",
    "CLAUDE.md",
    "README.md"
  ]

  # The same coarse chars-per-token heuristic `Kazi.Memory.AttemptLedger` uses
  # for its rendering budget — good enough for a soft cap, not a tokenizer.
  @chars_per_token 4

  # A cap on how many ranked rows are pulled from SQLite before budget-fitting,
  # so a huge corpus can never make one recall call scan unboundedly.
  @candidate_limit 50

  @doc "The default corpus globs (ADR-0062 decision 1), relative to a workspace."
  @spec default_corpus() :: [String.t()]
  def default_corpus, do: @default_corpus

  @doc """
  Budgeted recall (decision 3): refreshes the index for `corpus` under
  `workspace` (incrementally — see `refresh/2`), then returns a ranked slice
  of snippets for `query` GUARANTEED to fit `budget_tokens` (an approximate
  `#{@chars_per_token}` chars-per-token budget).

  `opts`:

    * `:workspace` — the corpus root (default `"."`).
    * `:corpus` — glob list to index, relative to `:workspace` (default
      `default_corpus/0`); an empty list (`[]`) is a valid opt-out and always
      recalls `[]` at zero cost.

  A `query` with no usable search term, or a corpus with no matching files,
  returns `[]` — never an error (recall degrades to silence, not a crash).
  """
  @spec recall(String.t(), non_neg_integer(), keyword()) :: [snippet()]
  def recall(query, budget_tokens, opts \\ [])
      when is_binary(query) and is_integer(budget_tokens) and budget_tokens >= 0 do
    workspace = Keyword.get(opts, :workspace, ".")
    corpus = Keyword.get(opts, :corpus) || @default_corpus

    :ok = refresh(workspace, corpus)
    max_chars = budget_tokens * @chars_per_token

    case build_match_query(query) do
      nil -> []
      match -> match |> search(workspace, corpus) |> fit_budget(max_chars)
    end
  end

  @doc """
  The stable scoping key for a workspace (issue #977): its canonicalized
  absolute path (`Path.expand/1`), so `"."` and its real absolute path always
  resolve to the same `workspace_root` — the identity two different callers
  (a goal's own `--workspace` vs. `Kazi.Loop`'s stored one) must agree on for
  scoping to actually prevent cross-workspace collisions.
  """
  @spec workspace_root(String.t()) :: String.t()
  def workspace_root(workspace) when is_binary(workspace), do: Path.expand(workspace)

  @doc """
  Incrementally refreshes the FTS index for `corpus` (glob patterns relative
  to `workspace`): each matching file is re-chunked ONLY when its current
  sha256 content hash differs from the one it was last indexed at
  (`Kazi.ReadModel.MemoryIndexFile`). An empty/no-match corpus is a no-op.
  """
  @spec refresh(String.t(), [String.t()]) :: :ok
  def refresh(workspace, corpus) when is_binary(workspace) and is_list(corpus) do
    root = workspace_root(workspace)

    workspace
    |> expand_corpus(corpus)
    |> Enum.each(&refresh_file(workspace, root, &1))

    :ok
  end

  @doc """
  Chunks markdown `content` at heading granularity: a chunk starts at each
  ATX heading line (`#` through `######`); content before the first heading
  is its own leading chunk (empty `heading`). Blank/whitespace-only chunks
  are dropped. Pure and total.

  ## Examples

      iex> Kazi.Memory.SemanticIndex.chunk_markdown("# Title\\nbody\\n\\n## Sub\\nmore")
      [
        %{heading: "# Title", line_start: 1, line_end: 2, text: "# Title\\nbody"},
        %{heading: "## Sub", line_start: 4, line_end: 5, text: "## Sub\\nmore"}
      ]
  """
  @spec chunk_markdown(String.t()) :: [chunk()]
  def chunk_markdown(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce([], &fold_line/2)
    |> Enum.reverse()
    |> Enum.map(&finalize_chunk/1)
    |> Enum.reject(&(&1.text == ""))
  end

  # ===========================================================================
  # Internal — chunking
  # ===========================================================================

  @heading_re ~r/^\#{1,6}\s/

  defp fold_line({line, lineno}, [current | rest] = chunks) do
    if heading?(line) do
      [%{heading: line, line_start: lineno, line_end: lineno, lines: [line]} | chunks]
    else
      [%{current | line_end: lineno, lines: [line | current.lines]} | rest]
    end
  end

  defp fold_line({line, lineno}, []) do
    if heading?(line) do
      [%{heading: line, line_start: lineno, line_end: lineno, lines: [line]}]
    else
      [%{heading: "", line_start: lineno, line_end: lineno, lines: [line]}]
    end
  end

  defp heading?(line), do: Regex.match?(@heading_re, line)

  defp finalize_chunk(%{heading: heading, line_start: s, line_end: e, lines: lines}) do
    %{
      heading: heading,
      line_start: s,
      line_end: e,
      text: lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
    }
  end

  # ===========================================================================
  # Internal — indexing
  # ===========================================================================

  @spec expand_corpus(String.t(), [String.t()]) :: [String.t()]
  defp expand_corpus(_workspace, []), do: []

  defp expand_corpus(workspace, corpus) do
    corpus
    |> Enum.flat_map(&Path.wildcard(Path.join(workspace, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp refresh_file(workspace, root, abs_path) do
    rel_path = Path.relative_to(abs_path, workspace)

    with {:ok, content} <- File.read(abs_path) do
      hash = content_hash(content)

      case fetch_hash(root, rel_path) do
        {:ok, ^hash} -> :ok
        _ -> reindex_file(root, rel_path, content, hash)
      end
    else
      {:error, _posix} -> :ok
    end
  end

  defp content_hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp fetch_hash(root, path) do
    case Repo.get_by(MemoryIndexFile, workspace_root: root, path: path) do
      nil -> :error
      %MemoryIndexFile{content_hash: hash} -> {:ok, hash}
    end
  end

  defp reindex_file(root, path, content, hash) do
    delete_chunks(root, path)

    content
    |> chunk_markdown()
    |> Enum.each(&insert_chunk(root, path, &1))

    upsert_hash(root, path, hash)
  end

  defp delete_chunks(root, path) do
    Repo.query!("DELETE FROM memory_chunks_fts WHERE workspace_root = ? AND path = ?", [
      root,
      path
    ])
  end

  defp insert_chunk(root, path, %{heading: heading, line_start: s, line_end: e, text: text}) do
    Repo.query!(
      "INSERT INTO memory_chunks_fts (workspace_root, path, heading, line_start, line_end, body) VALUES (?, ?, ?, ?, ?, ?)",
      [root, path, heading, s, e, text]
    )
  end

  defp upsert_hash(root, path, hash) do
    %MemoryIndexFile{}
    |> MemoryIndexFile.changeset(%{workspace_root: root, path: path, content_hash: hash})
    |> Repo.insert!(
      on_conflict: {:replace, [:content_hash, :updated_at]},
      conflict_target: [:workspace_root, :path]
    )
  end

  # ===========================================================================
  # Internal — recall
  # ===========================================================================

  # An empty resolved corpus (no glob matched a file) searches nothing rather
  # than erroring against a table that may hold stale rows from a PRIOR
  # corpus — the "empty/missing corpus is valid, zero recall" contract. The
  # `workspace_root = ?` clause (issue #977) scopes every match to the CURRENT
  # workspace BEFORE the `path IN (...)` clause narrows to files the CURRENT
  # corpus actually resolves to, so neither a broader prior corpus on the same
  # workspace NOR another workspace entirely can leak a stale/foreign row into
  # this recall.
  defp search(_match, _workspace, []), do: []

  defp search(match, workspace, corpus) do
    root = workspace_root(workspace)

    case workspace |> expand_corpus(corpus) |> Enum.map(&Path.relative_to(&1, workspace)) do
      [] ->
        []

      paths ->
        placeholders = Enum.map_join(paths, ", ", fn _ -> "?" end)

        sql = """
        SELECT path, line_start, body, bm25(memory_chunks_fts) AS rank
        FROM memory_chunks_fts
        WHERE memory_chunks_fts MATCH ? AND workspace_root = ? AND path IN (#{placeholders})
        ORDER BY rank
        LIMIT #{@candidate_limit}
        """

        case Repo.query(sql, [match, root | paths]) do
          {:ok, %{rows: rows}} ->
            Enum.map(rows, fn [path, line_start, body, rank] ->
              %{path: path, line: line_start, text: body, score: rank * -1.0}
            end)

          {:error, _reason} ->
            []
        end
    end
  end

  # Splits `query` into bare alphanumeric/underscore terms and OR-joins them as
  # quoted FTS5 phrases (safe even against a term containing a literal quote —
  # `escape_quotes/1` doubles it, FTS5's own escape convention). `nil` for a
  # query with no usable term, so the caller skips the search entirely.
  defp build_match_query(query) do
    case query |> String.split(~r/[^[:alnum:]_]+/u, trim: true) |> Enum.uniq() do
      [] -> nil
      terms -> terms |> Enum.map_join(" OR ", &~s("#{escape_quotes(&1)}"))
    end
  end

  defp escape_quotes(term), do: String.replace(term, "\"", "\"\"")

  # Fits ranked `rows` (best-first) to `max_chars`, GUARANTEEING the joined
  # text never exceeds the budget. Rows are taken whole while they fit; the
  # first row that does NOT fit is truncated (never dropped-with-overflow) iff
  # nothing has been kept yet — once at least one row is kept, later rows that
  # don't fit are simply dropped.
  defp fit_budget(_rows, max_chars) when max_chars <= 0, do: []

  defp fit_budget(rows, max_chars) do
    {kept, _used} = Enum.reduce_while(rows, {[], 0}, &fit_row(&1, &2, max_chars))
    Enum.reverse(kept)
  end

  defp fit_row(row, {[], 0}, max_chars) do
    text = row.text
    remaining = max_chars

    if byte_size(text) <= remaining do
      {:cont, {[row], byte_size(text)}}
    else
      {:halt, {[%{row | text: String.slice(text, 0, remaining)}], remaining}}
    end
  end

  defp fit_row(row, {kept, used}, max_chars) do
    remaining = max_chars - used

    if byte_size(row.text) <= remaining do
      {:cont, {[row | kept], used + byte_size(row.text)}}
    else
      {:halt, {kept, used}}
    end
  end
end
