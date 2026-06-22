defmodule Kazi.Retrieval.Graphify do
  @moduledoc """
  The real `Kazi.Retrieval` backend (T4.9b, ADR-0012): graphify-embeddings
  similarity recall.

  Given the failing predicates and a workspace, it embeds the target and does a
  similarity search for the failing evidence's terms, returning the top-k most
  relevant `Kazi.Retrieval.Snippet`s. This is the optional, similarity-based
  augmentation ADR-0005 deferred and ADR-0012 builds — layered *on top of* the
  deterministic orientation pack (ADR-0010) and the thin evidence projection
  (ADR-0009), never replacing them. It is engaged only when a goal opts in;
  `Kazi.Retrieval.NoOp` remains the default.

  ## External tool, behind an injectable command seam

  graphify is an external CLI/skill that produces embeddings and a similarity
  search — a heavyweight, non-deterministic dependency. So, exactly like
  `Kazi.Context.GraphCli`, this backend shells out behind an injectable command
  opt and is **never** invoked by the hermetic suite: unit tests pass a stub
  executable (a shell script emitting fixture matches) and assert the ranking +
  top-k logic; only the integration test (`@tag :graphify`, excluded by default)
  exercises the real tool. There is **no Elixir embeddings dependency** — the
  embedding work lives in the external command, not in `mix.exs`.

  ## Query

  The query is the set of path-ish / identifier-ish terms named in the failing
  evidence (the same tokens `Kazi.Context` ranks orientation by), so the
  similarity search is anchored on where the failing work lives. The terms are
  deduped and sorted for a stable query string.

  ## Ranking and top-k

  graphify returns scored matches; this backend sorts by descending score (a
  stable, deterministic tiebreak on `{-score, source, text}` so equal scores keep
  a total order) and keeps the top `:top_k` (default #{5}). Each match becomes a
  `Kazi.Retrieval.Snippet` carrying the match text and its `source` provenance.

  ## Degrade to `[]`, never fail the loop

  Retrieval *augments*; a retrieval failure must never fail a dispatch. A missing
  command, a non-zero exit, or unparseable output therefore degrades to `[]` (no
  retrieval section is appended) rather than raising — mirroring how a graph CLI
  error degrades to the repo-map fallback in `Kazi.Context.GraphCli`.

  ## Command

  Resolution order for the executable: `opts[:graphify_command]` > app config
  `config :kazi, Kazi.Retrieval.Graphify, command: ...` > the default
  `"graphify"`.

  ## Opts

    * `:top_k` — max snippets to return (default `5`).
    * `:graphify_command` — the executable to shell out to (test seam).
    * `:workspace` is the `retrieve/3` argument, not an opt; the command runs with
      `cd:` set to it so embeddings cover the target.
  """

  @behaviour Kazi.Retrieval

  alias Kazi.PredicateResult
  alias Kazi.Retrieval.Snippet

  @default_command "graphify"
  @default_top_k 5

  @impl true
  @spec retrieve(
          [{Kazi.Predicate.id(), PredicateResult.t()}],
          String.t(),
          keyword()
        ) :: [Snippet.t()]
  def retrieve(failing, workspace, opts \\ [])
      when is_list(failing) and is_binary(workspace) and is_list(opts) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    terms = evidence_terms(failing)

    case search(workspace, terms, opts) do
      {:ok, matches} -> matches |> rank() |> Enum.take(top_k) |> Enum.map(&to_snippet/1)
      # Retrieval augments; a failure degrades to no snippets, never a crash.
      {:error, _reason} -> []
    end
  end

  # Shell out to graphify's similarity search over the embedded target, asking for
  # JSON. `--query` carries the failing evidence terms; `cd:` scopes the embedding
  # to the workspace. A missing binary / non-zero exit is an :error (-> []), never
  # a crash, so a retrieval failure can never fail the dispatch.
  defp search(workspace, terms, opts) do
    command = command(opts)
    args = ["similarity-search", "--format", "json", "--query", Enum.join(terms, " ")]

    try do
      case System.cmd(command, args, cd: workspace, stderr_to_stdout: true) do
        {output, 0} -> decode(output)
        {output, _nonzero} -> {:error, {:graphify_failed, String.trim(output)}}
      end
    rescue
      error in ErlangError ->
        case error.original do
          :enoent -> {:error, {:command_not_found, command}}
          other -> {:error, other}
        end
    end
  end

  # Parse graphify's JSON into a list of match maps. Parsing is total: a shape we
  # do not recognise is an :error (-> []), never a crash.
  defp decode(output) do
    with {:ok, %{"matches" => matches}} when is_list(matches) <- Jason.decode(output) do
      {:ok, Enum.filter(matches, &valid_match?/1)}
    else
      {:ok, _other} -> {:error, :unexpected_graphify_json}
      {:error, _} = err -> err
    end
  end

  defp valid_match?(%{"text" => text}) when is_binary(text), do: true
  defp valid_match?(_), do: false

  # Highest similarity first; a stable, total tiebreak on {source, text} so equal
  # scores never reorder between runs (the determinism ADR-0012 asks of a backend
  # given fixed state).
  defp rank(matches) do
    Enum.sort_by(matches, fn match ->
      {-score(match), source(match) || "", Map.fetch!(match, "text")}
    end)
  end

  defp score(%{"score" => score}) when is_number(score), do: score
  defp score(_), do: 0.0

  defp source(%{"source" => source}) when is_binary(source), do: source
  defp source(_), do: nil

  defp to_snippet(match), do: Snippet.new(Map.fetch!(match, "text"), source: source(match))

  # The query terms: path-ish / identifier-ish tokens named in the failing
  # evidence (the predicate ids plus their evidence text), deduped and sorted for
  # a stable query. Mirrors `Kazi.Context`'s evidence-term extraction so retrieval
  # is anchored on the same failing-work signal the orientation pack ranks by.
  defp evidence_terms(failing) do
    failing
    |> Enum.flat_map(fn {id, %PredicateResult{evidence: evidence}} ->
      [to_string(id) | evidence_strings(evidence)]
    end)
    |> Enum.flat_map(&tokenize/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp evidence_strings(evidence) do
    evidence
    |> Map.values()
    |> Enum.map(fn
      value when is_binary(value) -> value
      value -> inspect(value)
    end)
  end

  # Pull path-ish and identifier-ish tokens out of free-form evidence text.
  defp tokenize(text) do
    ~r{[A-Za-z0-9_./:-]+}
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.flat_map(fn token ->
      trimmed = String.trim_trailing(token, ":")
      base = trimmed |> String.split(":") |> List.first()
      [trimmed, base] |> Enum.filter(&(String.length(&1) > 1))
    end)
    |> Enum.uniq()
  end

  defp command(opts) do
    Keyword.get(opts, :graphify_command) ||
      Application.get_env(:kazi, __MODULE__, [])[:command] ||
      @default_command
  end
end
