defmodule Kazi.Harness.Profiles.GeminiCli do
  @moduledoc """
  The built-in `:gemini_cli` harness profile logic (ADR-0022, T37.1): the argv
  assembly and JSON-result parsing for Google's Gemini CLI (`gemini`), so the
  generic `Kazi.Harness.CliAdapter` (T8.2) can drive it through the same path as
  Claude, opencode, Codex, and Antigravity.

  Gemini is a FULLY-CONFORMANT addition under ADR-0022 (like Codex, unlike
  Antigravity): it runs non-interactively from a single prompt (`gemini -p
  "<prompt>"`), has first-class machine-parseable output (`-o/--output-format
  json`), and supports model selection (`-m/--model <m>`). It diverges from Claude
  at the same two boundary points a profile captures:

    * **argv** — `gemini -p "<prompt>" -o json --approval-mode yolo [-m <m>]`.
      `-p` is the non-interactive single-prompt flag, `-o json` selects the JSON
      envelope, and `--approval-mode yolo` auto-approves tool actions so the run
      is non-interactive (the analogue of Antigravity's `--yes`: kazi drives every
      harness as a subprocess with no human at the keyboard, ADR-0001/ADR-0022, so
      a harness that would otherwise PROMPT before taking an action must be told to
      proceed). `-m <m>` is optional.
    * **stdout** — like Claude/Antigravity (and unlike the Codex/opencode JSONL
      streams), `-o json` emits a single JSON object (an ENVELOPE), not a
      newline-delimited event stream.

  Auth is `GEMINI_API_KEY` (or Google OAuth / Vertex `GOOGLE_API_KEY`), supplied
  by the operator's environment (forwarded via the CliAdapter's `opts[:env]`,
  T8.8) — not a profile concern.

  Both functions are PURE; `System.cmd` lives in the CliAdapter.

  ## Result shape this parser keys off (`gemini -o json`)

  The `-o json` envelope (recorded from `gemini` v0.38.2's `JsonFormatter.format`)
  is a single JSON object:

      {
        "session_id": "<id>",            // present only if a session id exists
        "response": "<assistant text>",  // the final answer, present on success
        "stats": { ... },                // session metrics; token counts live nested
                                         // under stats.models.<model>.tokens
        "error": { "type": "...", "message": "...", "code": <int optional> }
      }

  Extraction is additive and tolerant:

    * the top-level `response` text becomes `:result`;
    * token counts under `stats.models.<model>.tokens` (`totalTokenCount`, else
      `promptTokenCount` + `candidatesTokenCount`) are summed across the reported
      models to a token total surfaced as `:tokens` and `:cost => %{tokens: n}`;
      when the stats carry no usable count the token keys are OMITTED (no
      fabricated counts — the budget falls back to an estimate, ADR-0008);
    * on an error envelope (an `error` object with a `message`) where no
      `response` is present, the error message is surfaced as `:error` and
      `:result` is left ABSENT — the loop saw no agent answer, so claiming one
      would be a fabrication.

  Additive + total: malformed/empty/non-JSON output yields `%{}` and never
  crashes, so the CliAdapter keeps its base map (`:output`) and the budget's token
  dimension degrades to an estimate rather than a fabricated count.
  """

  # =============================================================================
  # argv assembly (contract: gemini v0.38.2 `gemini --help`, ADR-0022)
  # =============================================================================

  @doc """
  Renders the args AFTER the `gemini` command for `prompt`/`opts`.

  `-p <prompt> -o json --approval-mode yolo` is the always-present
  non-interactive + JSON-envelope shape. `--approval-mode yolo` is REQUIRED:
  kazi drives the harness as a subprocess with no interactive approver, so the
  agent must be allowed to take tool actions without a prompt. `-m <m>` is
  appended ONLY when `opts[:model]` is a non-empty string, so with no model the
  argv is the bare `["-p", prompt, "-o", "json", "--approval-mode", "yolo"]`.
  """
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) when is_binary(prompt) and is_list(opts) do
    ["-p", prompt, "-o", "json", "--approval-mode", "yolo"] ++ model_args(opts)
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> ["-m", model]
      _ -> []
    end
  end

  # =============================================================================
  # JSON-result parsing (-o json: a single envelope, best-effort + tolerant)
  # =============================================================================

  @doc """
  Parses Gemini's `-o json` envelope into the additive subset of the result map.
  Best-effort and total: empty/malformed/non-JSON output, or an envelope with no
  recognised field, yields `%{}` (never crashes).

  From the decoded object:

    * the top-level `response` text becomes `:result`;
    * the token counts under `stats.models.<model>.tokens` are summed to a token
      total surfaced as `:tokens` and `:cost => %{tokens: n}`; when no usable
      count is present the token keys are OMITTED;
    * an `error` object's `message` (when no `response` is present) becomes
      `:error`, with `:result` left absent.
  """
  @spec parse(String.t()) :: map()
  def parse(output) when is_binary(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, %{} = envelope} -> extract(envelope)
      _ -> %{}
    end
  end

  defp extract(envelope) do
    %{}
    |> maybe_result(envelope)
    |> maybe_error(envelope)
    |> maybe_tokens(envelope)
    |> finalize()
  end

  defp maybe_result(acc, envelope) do
    case find_result(envelope) do
      text when is_binary(text) and text != "" -> Map.put(acc, :result, text)
      _ -> acc
    end
  end

  # Surface the error message ONLY when there is no agent response to report:
  # the loop saw no answer, so :result stays absent and :error carries the cause.
  defp maybe_error(acc, envelope) do
    if Map.has_key?(acc, :result) do
      acc
    else
      case find_error(envelope) do
        message when is_binary(message) and message != "" -> Map.put(acc, :error, message)
        _ -> acc
      end
    end
  end

  defp maybe_tokens(acc, envelope) do
    case find_tokens(envelope) do
      total when is_integer(total) and total > 0 -> Map.put(acc, :tokens, total)
      _ -> acc
    end
  end

  # Surface the carried token total as :cost => %{tokens: n}.
  defp finalize(acc) do
    case Map.get(acc, :tokens) do
      total when is_integer(total) and total > 0 -> Map.put(acc, :cost, %{tokens: total})
      _ -> acc
    end
  end

  # --- result/error extraction -----------------------------------------------

  @spec find_result(map()) :: String.t() | nil
  defp find_result(%{"response" => text}) when is_binary(text), do: text
  defp find_result(_), do: nil

  @spec find_error(map()) :: String.t() | nil
  defp find_error(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp find_error(_), do: nil

  # --- token extraction ------------------------------------------------------

  # Token counts live nested under stats.models.<model>.tokens. Sum each model's
  # contribution (preferring its totalTokenCount, else prompt + candidates) across
  # every reported model; an absent/empty stats block yields nil (no fabrication).
  @spec find_tokens(map()) :: non_neg_integer() | nil
  defp find_tokens(%{"stats" => %{"models" => %{} = models}}) do
    total =
      models
      |> Map.values()
      |> Enum.reduce(0, fn model, sum -> sum + model_tokens(model) end)

    if total > 0, do: total, else: nil
  end

  defp find_tokens(_), do: nil

  @spec model_tokens(term()) :: non_neg_integer()
  defp model_tokens(%{"tokens" => %{} = tokens}) do
    case Map.get(tokens, "totalTokenCount") do
      n when is_integer(n) and n >= 0 -> n
      _ -> component_sum(tokens, ["promptTokenCount", "candidatesTokenCount"])
    end
  end

  defp model_tokens(_), do: 0

  defp component_sum(tokens, keys) do
    Enum.reduce(keys, 0, fn key, sum ->
      case Map.get(tokens, key) do
        n when is_integer(n) and n >= 0 -> sum + n
        _ -> sum
      end
    end)
  end
end
