defmodule Kazi.Harness.Profiles.Codex do
  @moduledoc """
  The built-in `:codex` harness profile logic (ADR-0022, T14.2): the argv
  assembly and JSONL event-stream parsing for `codex exec "<prompt>" --json
  [--model <m>]`, so the generic `Kazi.Harness.CliAdapter` (T8.2) can drive
  OpenAI's Codex CLI through the same path as Claude and opencode.

  Codex is the priority FULLY-CONFORMANT addition under ADR-0022: it runs
  non-interactively from a single prompt, emits machine-parseable output to
  stdout under a non-TTY subprocess, and supports model selection. It diverges
  from Claude at the same two boundary points a profile captures:

    * **argv** — `codex exec "<prompt>" --json [--model <m>]` (the contract
      recorded in `docs/devlog.md` 2026-06-23; auth is `OPENAI_API_KEY` / `codex
      login`). `exec` is Codex's non-interactive subcommand, `--json` selects the
      JSONL event stream, `--model` is optional.
    * **stdout** — like opencode (and unlike Claude's single JSON envelope),
      `--json` emits a **newline-delimited JSON (JSONL) event stream**, one event
      per line: `thread.started`, `item.*` (`item.started`/`item.updated`/
      `item.completed`), `turn.completed`, and `error`. The final agent answer
      arrives on the terminal `item.completed`/`turn.completed` events; token
      usage arrives on `turn.completed`.

  Both functions are PURE; `System.cmd` lives in the CliAdapter. The parser
  MIRRORS `Kazi.Harness.Profiles.Opencode`'s NDJSON path: it decodes each line
  independently, scans every decoded object best-effort, and carries the
  last-seen agent text and token usage so a shape change in a non-result event
  cannot crash extraction.

  ## Event shape this parser keys off (Codex `exec --json`)

  Each JSONL line is one event. The ones this parser extracts from:

    * **agent message item** — the assistant's final text. Codex carries it as an
      `item` of type `agent_message` (a.k.a. `assistant_message`) with a `text`
      field, on `item.completed`/`item.updated`:
      `{"type":"item.completed","item":{"type":"agent_message","text":"…"}}`.
      The LAST such text is taken as the final `:result`.
    * **turn.completed usage** — token accounting for the turn:
      `{"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,
      "output_tokens":N}}`. The last usage object wins; its counts are summed to a
      token total surfaced as `:tokens` and `:cost => %{tokens: n}`.

  To stay robust to Codex shape drift (item-vs-top-level `text`, usage on the
  turn vs. nested), extraction is best-effort and tolerant: it scans EVERY
  decoded object for a usable `text`/`usage` regardless of the exact wrapping
  event, and ignores anything it does not recognise.

  Additive + total: malformed/empty output yields `%{}` and never crashes, so the
  CliAdapter keeps its base map and the budget's token dimension degrades to an
  estimate (ADR-0008) rather than a fabricated count.
  """

  # =============================================================================
  # argv assembly (contract: docs/devlog.md 2026-06-23, ADR-0022)
  # =============================================================================

  @doc """
  Renders the args AFTER the `codex` command for `prompt`/`opts`.

  `exec <prompt> --json` is the always-present non-interactive + JSONL-event
  shape. `--model <m>` is appended ONLY when `opts[:model]` is a non-empty
  string, so with no model the argv is the bare `["exec", prompt, "--json"]`.
  """
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) when is_binary(prompt) and is_list(opts) do
    ["exec", prompt, "--json"] ++ model_args(opts)
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> ["--model", model]
      _ -> []
    end
  end

  # =============================================================================
  # JSONL event-stream parsing (mirrors Kazi.Harness.Profiles.Opencode)
  # =============================================================================

  @doc """
  Parses the `codex exec --json` JSONL event stream into the additive subset of
  the result map. Best-effort and total: empty/malformed output, or a stream with
  no recognised event, yields `%{}` (never crashes).

  Each line is JSON-decoded independently; non-JSON lines are skipped. From the
  decoded events:

    * the LAST agent-message `text` becomes `:result`;
    * the LAST `turn.completed` `usage` object (`{input_tokens,
      cached_input_tokens, output_tokens}`) is summed to a token total, surfaced
      as `:tokens` and `:cost => %{tokens: n}`; when no usage is reported the
      token keys are OMITTED (no fabricated counts — the budget falls back to an
      estimate, ADR-0008). The SAME last usage object is mapped onto the per-field
      economy envelope (`:usage`/`:usage_raw`/`:usage_fidelity`, T34.2 below).
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

  # Carry the last-seen agent text and the last-seen token total. "Last wins"
  # mirrors Codex emitting incremental item updates then a terminal completion.
  defp accumulate(event, acc) do
    acc
    |> maybe_text(event)
    |> maybe_tokens(event)
    |> maybe_usage_raw(event)
  end

  defp maybe_text(acc, event) do
    case find_agent_text(event) do
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

  # T34.2 (ADR-0046): carry the LAST-seen raw usage OBJECT (under a private key
  # stripped in `finalize/1`) so the per-field economy envelope can be mapped
  # from it. Distinct from `maybe_tokens/2` (which carries the summed total for
  # the budget rollup): the split needs the un-summed object, last-wins to match
  # Codex emitting incremental then terminal `turn.completed` usage.
  defp maybe_usage_raw(acc, event) do
    case usage_object(event) do
      %{} = usage -> Map.put(acc, :__usage_raw, usage)
      _ -> acc
    end
  end

  # Surface the carried token total as :cost => %{tokens: n}, and the carried raw
  # usage object as the per-field economy envelope, stripping the private carry.
  defp finalize(acc) do
    acc
    |> finalize_cost()
    |> finalize_usage()
  end

  defp finalize_cost(acc) do
    case Map.get(acc, :tokens) do
      total when is_integer(total) and total > 0 -> Map.put(acc, :cost, %{tokens: total})
      _ -> acc
    end
  end

  # The Codex usage object → economy-envelope field map (T34.2). Codex reports
  # the cached/fresh split natively (`cached_input_tokens`), so each field carries
  # to its own envelope field rather than being summed away; a field the stream
  # did not report is OMITTED (absent ≠ zero), and a turn with no usage object is
  # `:usage_fidelity => :none`.
  @usage_mapping [
    {"input_tokens", :input_tokens},
    {"cached_input_tokens", :cached_input_tokens},
    {"output_tokens", :output_tokens}
  ]

  defp finalize_usage(acc) do
    case Map.pop(acc, :__usage_raw) do
      {nil, acc} -> mark_no_usage(acc)
      {usage, acc} -> map_usage(acc, usage)
    end
  end

  # No usage object anywhere in the stream. Mark `:none` only when a turn was
  # otherwise parsed (a `:result`): a fully-empty or unrecognized stream stays
  # `%{}` — there is no harness turn to annotate, matching the additive contract.
  defp mark_no_usage(acc) when map_size(acc) == 0, do: acc
  defp mark_no_usage(acc), do: Map.put(acc, :usage_fidelity, :none)

  defp map_usage(acc, usage) do
    case Kazi.Harness.Usage.map(usage, @usage_mapping) do
      {_envelope, :none} ->
        Map.put(acc, :usage_fidelity, :none)

      {envelope, fidelity} ->
        acc
        |> Map.put(:usage, envelope)
        |> Map.put(:usage_raw, usage)
        |> Map.put(:usage_fidelity, fidelity)
    end
  end

  # --- text extraction -------------------------------------------------------

  # An agent-message item: {"item":{"type":"agent_message","text":"…"}} (Codex
  # also names it "assistant_message"), or any object directly shaped like one.
  @spec find_agent_text(map()) :: String.t() | nil
  defp find_agent_text(event) do
    item = item_of(event)

    cond do
      agent_message?(item) -> Map.get(item, "text")
      agent_message?(event) -> Map.get(event, "text")
      true -> nil
    end
  end

  defp agent_message?(%{"type" => type, "text" => text})
       when type in ["agent_message", "assistant_message"] and is_binary(text),
       do: true

  defp agent_message?(_), do: false

  defp item_of(%{"item" => %{} = item}), do: item
  defp item_of(_), do: nil

  # --- token extraction ------------------------------------------------------

  # Codex usage object: {input_tokens, cached_input_tokens, output_tokens},
  # carried on the terminal `turn.completed` event (or nested under an item).
  @spec find_tokens(map()) :: non_neg_integer() | nil
  defp find_tokens(event) do
    case usage_object(event) do
      %{} = usage -> sum_tokens(usage)
      _ -> nil
    end
  end

  defp usage_object(%{"usage" => %{} = u}), do: u
  defp usage_object(%{"item" => %{"usage" => %{} = u}}), do: u
  defp usage_object(_), do: nil

  @spec sum_tokens(map()) :: non_neg_integer()
  defp sum_tokens(usage) do
    ["input_tokens", "cached_input_tokens", "output_tokens"]
    |> Enum.reduce(0, fn key, sum ->
      case Map.get(usage, key) do
        n when is_integer(n) and n >= 0 -> sum + n
        _ -> sum
      end
    end)
  end
end
