defmodule Kazi.Harness.Profiles.Opencode do
  @moduledoc """
  The built-in `:opencode` harness profile logic (ADR-0016, T8.4): the argv
  assembly and NDJSON event-stream parsing for `opencode run <prompt> --format
  json`, so the generic `Kazi.Harness.CliAdapter` (T8.2) can drive opencode
  through the same path as Claude.

  opencode diverges from Claude at the same two boundary points a profile
  captures:

    * **argv** — `opencode run <prompt> --format json [--dir <workspace>]
      [--model <provider/model>]` (verified against the installed `opencode`
      CLI, v1.17.9: `opencode run --help`). `--model` is `provider/model`
      (e.g. `local-ollama/qwen3.6:35b-a3b`). `--dir` ("directory to run in")
      pins the run to the goal's workspace: unlike Claude, `opencode run` does
      NOT honor the launch cwd the CliAdapter sets via `System.cmd(..., cd:
      workspace)` — it resolves its own project root (and may attach to a
      persistent server), so without `--dir` the inner agent's edits land
      OUTSIDE the workspace and kazi's workspace-scoped predicates never see
      them (T39.7; docs/lore.md L-0035).
    * **stdout** — unlike Claude's single JSON envelope, `--format json` emits a
      **stream of JSON events, one per line (NDJSON)**: server-bus MessageV2
      events such as `message.part.updated` (carrying a `part`) and
      `message.updated` (carrying the assistant message `info`). It also writes
      the trimmed text of each completed `text` part to stdout in non-TTY mode.

  Both functions are PURE; `System.cmd` lives in the CliAdapter.

  ## Event shape this parser keys off (grounded in opencode v1.17.9)

  The parser was built against opencode's real MessageV2 schema — confirmed by
  inspecting the installed binary's embedded zod schemas and one live `step_start`
  event captured from `opencode run … --format json`, NOT a full live transcript
  (a locally-hosted 35B model did not complete a turn inside the capture
  window; Risk R-E8-1). Concretely, each NDJSON line is one of:

    * `{"type":"message.part.updated","properties":{"part":{"type":"text",
      "text":"…"}}}` — an assistant TEXT part. Its `text` is the assistant
      output; the LAST such part is taken as the final `:result`.
    * `{"type":"message.updated","properties":{"info":{"role":"assistant",
      "tokens":{"input":N,"output":N,"reasoning":N,"cache":{"read":N,"write":N}},
      "cost":F}}}` — the assistant message. opencode's `tokens` object is
      `{input, output, reasoning, cache:{read, write}}` and `cost` is a USD
      number. The last assistant `info` carrying usage wins.

  To stay robust to opencode shape drift (parts vs. step-finish, top-level vs.
  nested `text`/`tokens`/`cost`), extraction is best-effort and tolerant: it
  scans EVERY decoded object for a usable `text`/`tokens`/`cost` regardless of
  the exact wrapping event, and ignores anything it does not recognise.

  Additive + total: malformed/empty output yields `%{}` and never crashes, so the
  CliAdapter keeps its base map and the budget's token dimension degrades to an
  estimate (ADR-0008) rather than a fabricated count.
  """

  # =============================================================================
  # argv assembly (verified: `opencode run --help`, v1.17.9)
  # =============================================================================

  @doc """
  Renders the args AFTER the `opencode` command for `prompt`/`opts`.

  `run <prompt> --format json` is the always-present non-interactive +
  NDJSON-event shape. `--dir <workspace>` is appended when `opts[:workspace]`
  is a non-empty string (the CliAdapter threads the run's workspace in;
  T39.7 — `opencode run` ignores the launch cwd, so `--dir` is what actually
  scopes the inner agent's edits to the goal's workspace). `--model
  <provider/model>` is appended ONLY when `opts[:model]` is a non-empty
  string, so with neither the argv is the bare
  `["run", prompt, "--format", "json"]`.
  """
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) when is_binary(prompt) and is_list(opts) do
    ["run", prompt, "--format", "json"] ++ dir_args(opts) ++ model_args(opts)
  end

  defp dir_args(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" -> ["--dir", workspace]
      _ -> []
    end
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> ["--model", model]
      _ -> []
    end
  end

  # =============================================================================
  # NDJSON event-stream parsing
  # =============================================================================

  @doc """
  Parses the `opencode run --format json` NDJSON event stream into the additive
  subset of the result map. Best-effort and total: empty/malformed output, or a
  stream with no recognised event, yields `%{}` (never crashes).

  Each line is JSON-decoded independently; non-JSON lines (e.g. a trailing
  plain-text echo of the final part in non-TTY mode) are skipped. From the
  decoded events:

    * the LAST assistant TEXT part's `text` becomes `:result`;
    * the LAST assistant `tokens` object (`{input, output, reasoning,
      cache:{read, write}}`) is summed to a token total, surfaced as `:tokens`
      and `:cost => %{tokens: n}`; when no usage is reported the token keys are
      OMITTED (no fabricated counts — the budget falls back to an estimate);
    * a USD `cost` number becomes `:cost_usd`.
  """
  @spec parse(String.t()) :: map()
  def parse(output) when is_binary(output) do
    output
    |> decode_events()
    |> Enum.reduce(%{}, &accumulate/2)
    |> finalize()
  end

  # Split on newlines and JSON-decode each line, keeping only decoded OBJECTS.
  @spec decode_events(String.t()) :: [map()]
  defp decode_events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{} = event} -> [event]
        _ -> []
      end
    end)
  end

  # Carry the last-seen text, the last-seen token total, and the last-seen cost.
  # "Last wins" mirrors opencode emitting incremental then final values.
  defp accumulate(event, acc) do
    acc
    |> maybe_text(event)
    |> maybe_tokens(event)
    |> maybe_cost(event)
  end

  defp maybe_text(acc, event) do
    case find_assistant_text(event) do
      text when is_binary(text) -> Map.put(acc, :result, text)
      _ -> acc
    end
  end

  defp maybe_tokens(acc, event) do
    case find_tokens(event) do
      total when is_integer(total) and total > 0 -> Map.put(acc, :tokens, total)
      _ -> acc
    end
  end

  defp maybe_cost(acc, event) do
    case find_cost(event) do
      cost when is_number(cost) -> Map.put(acc, :cost_usd, cost)
      _ -> acc
    end
  end

  # Surface the carried token total as both :tokens and :cost => %{tokens: n}.
  defp finalize(acc) do
    case Map.get(acc, :tokens) do
      total when is_integer(total) and total > 0 -> Map.put(acc, :cost, %{tokens: total})
      _ -> acc
    end
  end

  # --- text extraction -------------------------------------------------------

  # An assistant TEXT part: {"part":{"type":"text","text":"…"}} (possibly wrapped
  # in {"properties":{"part":…}}), or any object directly shaped like a text part.
  @spec find_assistant_text(map()) :: String.t() | nil
  defp find_assistant_text(event) do
    part = part_of(event)

    cond do
      text_part?(part) -> Map.get(part, "text")
      text_part?(event) -> Map.get(event, "text")
      true -> nil
    end
  end

  defp text_part?(%{"type" => "text", "text" => text}) when is_binary(text), do: true
  defp text_part?(_), do: false

  defp part_of(%{"properties" => %{"part" => %{} = part}}), do: part
  defp part_of(%{"part" => %{} = part}), do: part
  defp part_of(_), do: nil

  # --- token extraction ------------------------------------------------------

  # opencode tokens object: {input, output, reasoning, cache:{read, write}}.
  # Found on the assistant message info (message.updated) or a step-finish part.
  @spec find_tokens(map()) :: non_neg_integer() | nil
  defp find_tokens(event) do
    case tokens_object(event) do
      %{} = tokens -> sum_tokens(tokens)
      _ -> nil
    end
  end

  defp tokens_object(%{"properties" => %{"info" => %{"tokens" => %{} = t}}}), do: t
  defp tokens_object(%{"properties" => %{"part" => %{"tokens" => %{} = t}}}), do: t
  defp tokens_object(%{"info" => %{"tokens" => %{} = t}}), do: t
  defp tokens_object(%{"part" => %{"tokens" => %{} = t}}), do: t
  defp tokens_object(%{"tokens" => %{} = t}), do: t
  defp tokens_object(_), do: nil

  @spec sum_tokens(map()) :: non_neg_integer()
  defp sum_tokens(tokens) do
    flat =
      [Map.get(tokens, "input"), Map.get(tokens, "output"), Map.get(tokens, "reasoning")]

    cache =
      case Map.get(tokens, "cache") do
        %{} = c -> [Map.get(c, "read"), Map.get(c, "write")]
        _ -> []
      end

    (flat ++ cache)
    |> Enum.reduce(0, fn
      n, sum when is_integer(n) and n >= 0 -> sum + n
      _, sum -> sum
    end)
  end

  # --- cost extraction -------------------------------------------------------

  @spec find_cost(map()) :: number() | nil
  defp find_cost(%{"properties" => %{"info" => %{"cost" => cost}}}) when is_number(cost), do: cost
  defp find_cost(%{"properties" => %{"part" => %{"cost" => cost}}}) when is_number(cost), do: cost
  defp find_cost(%{"info" => %{"cost" => cost}}) when is_number(cost), do: cost
  defp find_cost(%{"part" => %{"cost" => cost}}) when is_number(cost), do: cost
  defp find_cost(%{"cost" => cost}) when is_number(cost), do: cost
  defp find_cost(_), do: nil
end
