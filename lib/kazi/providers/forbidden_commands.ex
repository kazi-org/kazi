defmodule Kazi.Providers.ForbiddenCommands do
  @moduledoc """
  The `:forbidden_commands` predicate provider (ADR-0085, kazi-org/kazi#1695/
  #1704): a best-effort scan of the dispatch transcript for a declared
  `[scope].forbidden_commands` pattern.

  **This is a tripwire, not a sandbox.** A dispatched harness run under
  `--permission-mode bypassPermissions` has real shell access this ADR does
  not attempt to revoke (#1704: a grind model opened a PR and edited a docs
  file despite an orchestrating session's own never-seen "do not" prose). A
  determined or confused model can run a forbidden command directly and this
  scan cannot stop it — it can only make the attempt VISIBLE, as a failing
  guard predicate naming the matched transcript line, fed back to the agent
  (and a human reading `--json` output) exactly like any other predicate.
  Structural enforcement — the kind this scan CANNOT provide — is what
  `[scope].forbidden_paths` and `[scope].no_integration` are for instead
  (`Kazi.Scope`, `Kazi.Actions.Integrate`): the controller's own tooling
  refuses, rather than merely detecting after the fact.

  `Kazi.Scope.guard_predicates/1` synthesizes this predicate automatically
  whenever a goal declares `forbidden_commands`, independent of the
  `[enforcement]` profile — a scope contract, not an anti-gaming one.

  ## What it scans

  The run's transcript sink (`Kazi.Sink.Transcript`, `context[:transcript_path]`,
  threaded by `Kazi.Runtime` from the same `transcript_sink_path` the harness
  adapter tees to) — one decoded JSONL event per line. A Claude Code
  `stream-json` `tool_use` block whose tool name is a shell-runner (`Bash`) has
  its `input` (the command line) matched against each declared pattern as a
  case-insensitive substring; a bare non-JSON transcript line is matched the
  same way as a fallback, so a non-Claude harness (whose transcript is plain
  text lines, per `Kazi.Sink.Transcript`) is still covered.

  No transcript available (no sink configured, nothing written yet, the file
  is missing) is NOT a violation — it degrades to a clean `:pass` with that
  noted in evidence, the same "advisory, never block on infra absence"
  contract `Kazi.Enforcement.DiffGuard` uses for a missing diff.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.PredicateResult
  alias Kazi.Sink.Transcript

  @typedoc "A flagged forbidden-command sighting."
  @type hit :: %{pattern: String.t(), snippet: String.t()}

  @impl true
  def evaluate(%Kazi.Predicate{config: config}, context) do
    patterns = Map.get(config || %{}, :forbidden_commands, [])
    transcript_path = Map.get(context, :transcript_path)

    case scan_path(transcript_path, patterns) do
      {:unavailable, reason} ->
        PredicateResult.pass(%{forbidden_commands: patterns, scanned: false, reason: reason})

      hits when hits == [] ->
        PredicateResult.pass(%{forbidden_commands: patterns, scanned: true, hits: []})

      hits ->
        PredicateResult.fail(%{
          reason: :forbidden_command_attempted,
          forbidden_commands: patterns,
          hits: hits
        })
    end
  end

  defp scan_path(nil, _patterns), do: {:unavailable, :no_transcript_configured}
  defp scan_path(_path, []), do: []

  defp scan_path(path, patterns) when is_binary(path) do
    if File.exists?(path) do
      path |> Transcript.read() |> scan(patterns)
    else
      {:unavailable, :transcript_not_found}
    end
  end

  @doc """
  Scans decoded transcript events (`Kazi.Sink.Transcript.read/1`'s shape) for a
  declared `forbidden_commands` pattern. Pure — no I/O, the caller owns fetching
  the transcript (mirrors `Kazi.Enforcement.DiffGuard.scan/2`'s design).

  Matching is a case-insensitive substring match of each pattern against: a
  `tool_use` event's `input` (JSON-encoded, so a nested `command` field is
  covered without knowing every harness's tool-call shape), or a plain-text
  event's `text`. Returns `[]` when nothing matches.

  ## Examples

      iex> events = [%{"type" => "assistant", "message" => %{"content" => [
      ...>   %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "gh pr create"}}
      ...> ]}}]
      iex> [hit] = Kazi.Providers.ForbiddenCommands.scan(events, ["gh pr create"])
      iex> hit.pattern
      "gh pr create"

      iex> Kazi.Providers.ForbiddenCommands.scan([%{"type" => "text", "text" => "git status"}], ["gh pr create"])
      []
  """
  @spec scan([map()], [String.t()]) :: [hit()]
  def scan(events, patterns) when is_list(events) and is_list(patterns) do
    for event <- events,
        haystack = haystack(event),
        pattern <- patterns,
        String.contains?(String.downcase(haystack), String.downcase(pattern)) do
      %{pattern: pattern, snippet: snippet(haystack)}
    end
  end

  def scan(_events, _patterns), do: []

  defp haystack(%{"text" => text}) when is_binary(text), do: text
  defp haystack(event) when is_map(event), do: safe_encode(event)
  defp haystack(_event), do: ""

  defp safe_encode(event) do
    case Jason.encode(event) do
      {:ok, json} -> json
      {:error, _} -> ""
    end
  end

  @snippet_cap 200
  defp snippet(text) when byte_size(text) <= @snippet_cap, do: text
  defp snippet(text), do: binary_part(text, 0, @snippet_cap) <> "…"
end
