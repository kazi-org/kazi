defmodule Kazi.Harness.Profiles.Antigravity do
  @moduledoc """
  The built-in `:antigravity` harness profile logic (ADR-0022, T14.3): the argv
  assembly and JSON-result parsing for Google's Antigravity CLI (`antigravity`,
  also installed as `agy`), so the generic `Kazi.Harness.CliAdapter` (T8.2) can
  drive it through the same path as Claude, opencode, and Codex.

  Antigravity is conformant under ADR-0022 only **WITH a documented workaround**.
  It runs non-interactively from a single prompt and can emit a machine-parseable
  JSON result, but there is a load-bearing bug:

  > **LANDMINE — `google-antigravity/antigravity-cli#76`.** Invoked with the bare
  > `--prompt`/`-p` flag, Antigravity SILENTLY DROPS its stdout when stdout is not
  > a TTY (a pipe/redirect/subprocess) — *exactly* kazi's mode (kazi drives every
  > harness as a non-interactive subprocess and parses stdout, ADR-0001/ADR-0022).
  > The process exits 0 with EMPTY stdout, so a naive `-p` profile would parse
  > nothing and the loop would think the agent said nothing.

  The workaround (ADR-0022, `docs/devlog.md` 2026-06-23): write the prompt to a
  TEMP FILE and invoke

      antigravity run --prompt-file <tmp> --output json --yes

  `--prompt-file` + `--output json` is the path that survives a non-TTY subprocess;
  `--yes` auto-approves so the run is non-interactive. This profile therefore sets
  `prompt_via: :file` (see `Kazi.Harness.Profile`): the `CliAdapter` writes the
  prompt to a temp file in the workspace and threads its path to `build_args` as
  `opts[:prompt_file]`, so `build_args` STAYS PURE — it only references the path
  the adapter materialized, never doing IO itself.

  Auth is `GEMINI_API_KEY` / `ANTIGRAVITY_API_KEY`, supplied by the operator's
  environment (forwarded via the CliAdapter's `opts[:env]`, T8.8) — not a profile
  concern.

  Both functions are PURE; `System.cmd` and the temp-file IO live in the
  CliAdapter.

  ## argv assembly

    * `run --prompt-file <tmp> --output json --yes` — the always-present
      non-interactive + JSON shape with the #76 workaround. `<tmp>` is the path the
      CliAdapter materialized (`opts[:prompt_file]`). `--model <m>` is appended ONLY
      when `opts[:model]` is a non-empty string.

  ## Result shape this parser keys off (`--output json`)

  Antigravity's `--output json` emits a single JSON object (an ENVELOPE, unlike the
  Codex/opencode JSONL streams). To stay robust to its exact shape, extraction is
  best-effort and tolerant — it accepts the assistant text under any of `result`,
  `response`, `text`, or a nested `message.content`, and token usage under a
  `usage` object with `input_tokens`/`output_tokens` (or a `total_tokens`):

    * the assistant text becomes `:result`;
    * the `usage` token counts are summed to a token total surfaced as `:tokens`
      and `:cost => %{tokens: n}`; when no usage is reported the token keys are
      OMITTED (no fabricated counts — the budget falls back to an estimate,
      ADR-0008).

  Additive + total: malformed/empty output (including the EMPTY stdout the #76 bug
  would produce if the workaround regressed) yields `%{}` and never crashes, so the
  CliAdapter keeps its base map and the budget's token dimension degrades to an
  estimate rather than a fabricated count.
  """

  # =============================================================================
  # argv assembly (contract: docs/devlog.md 2026-06-23, ADR-0022; #76 workaround)
  # =============================================================================

  @doc """
  Renders the args AFTER the `antigravity` command for `prompt`/`opts`.

  Uses the non-TTY workaround: `run --prompt-file <tmp> --output json --yes`, where
  `<tmp>` is `opts[:prompt_file]` — the temp-file path the `CliAdapter` wrote the
  prompt to (this profile declares `prompt_via: :file`). The `prompt` argument is
  intentionally IGNORED here: under the workaround the prompt travels via the file,
  NOT the argv, so the bare `--prompt`/`-p` flag (which drops stdout under a
  non-TTY, bug #76) is never used.

  `--model <m>` is appended ONLY when `opts[:model]` is a non-empty string.

  Raises if `opts[:prompt_file]` is absent — the CliAdapter always supplies it for
  a `prompt_via: :file` profile, so a missing path means the profile was driven
  outside the adapter (a programming error), and failing loud beats silently
  invoking the bug-prone bare-prompt form.
  """
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) when is_binary(prompt) and is_list(opts) do
    prompt_file = fetch_prompt_file!(opts)

    ["run", "--prompt-file", prompt_file, "--output", "json", "--yes"] ++ model_args(opts)
  end

  defp fetch_prompt_file!(opts) do
    case Keyword.get(opts, :prompt_file) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        raise ArgumentError,
              "Kazi.Harness.Profiles.Antigravity.build_args/2 requires opts[:prompt_file] " <>
                "(the CliAdapter supplies it for a prompt_via: :file profile — the non-TTY " <>
                "workaround for antigravity-cli#76)"
    end
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> ["--model", model]
      _ -> []
    end
  end

  # =============================================================================
  # JSON-result parsing (--output json: a single envelope, best-effort + tolerant)
  # =============================================================================

  @doc """
  Parses Antigravity's `--output json` envelope into the additive subset of the
  result map. Best-effort and total: empty/malformed output (including the EMPTY
  stdout the #76 bug produces if the workaround regresses), or an envelope with no
  recognised field, yields `%{}` (never crashes).

  From the decoded object:

    * the assistant text (`result` / `response` / `text` / nested
      `message.content`) becomes `:result`;
    * the `usage` token counts (`input_tokens` + `output_tokens`, or a
      `total_tokens`) are summed and surfaced as `:tokens` and `:cost =>
      %{tokens: n}`; when no usage is reported the token keys are OMITTED.
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
    |> maybe_text(envelope)
    |> maybe_tokens(envelope)
    |> finalize()
  end

  defp maybe_text(acc, envelope) do
    case find_text(envelope) do
      text when is_binary(text) and text != "" -> Map.put(acc, :result, text)
      _ -> acc
    end
  end

  defp maybe_tokens(acc, envelope) do
    case find_tokens(envelope) do
      total when is_integer(total) and total > 0 -> Map.put(acc, :tokens, total)
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

  # Accept the assistant text under any of the shapes Antigravity's --output json
  # may use: a top-level `result`/`response`/`text`, or a nested message content.
  @spec find_text(map()) :: String.t() | nil
  defp find_text(%{"result" => text}) when is_binary(text), do: text
  defp find_text(%{"response" => text}) when is_binary(text), do: text
  defp find_text(%{"text" => text}) when is_binary(text), do: text
  defp find_text(%{"message" => %{"content" => text}}) when is_binary(text), do: text
  defp find_text(_), do: nil

  # --- token extraction ------------------------------------------------------

  # Antigravity usage object: {input_tokens, output_tokens} (and possibly
  # total_tokens). Prefer summing the components; fall back to total_tokens.
  @spec find_tokens(map()) :: non_neg_integer() | nil
  defp find_tokens(%{"usage" => %{} = usage}), do: sum_tokens(usage)
  defp find_tokens(_), do: nil

  @spec sum_tokens(map()) :: non_neg_integer() | nil
  defp sum_tokens(usage) do
    components = component_sum(usage, ["input_tokens", "output_tokens"])

    cond do
      components > 0 -> components
      is_integer(usage["total_tokens"]) and usage["total_tokens"] > 0 -> usage["total_tokens"]
      true -> nil
    end
  end

  defp component_sum(usage, keys) do
    Enum.reduce(keys, 0, fn key, sum ->
      case Map.get(usage, key) do
        n when is_integer(n) and n >= 0 -> sum + n
        _ -> sum
      end
    end)
  end
end
