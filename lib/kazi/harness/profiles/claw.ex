defmodule Kazi.Harness.Profiles.Claw do
  @moduledoc """
  The built-in `:claw` harness profile logic (ADR-0022, T14.4): the argv
  assembly and raw-stdout parsing for claw-code (`claw prompt "<text>"`), so the
  generic `Kazi.Harness.CliAdapter` (T8.2) can drive it through the same path as
  Claude, opencode, Codex, and Antigravity.

  > **BEST-EFFORT / DEMO-GRADE — NOT a first-class harness.** claw-code does NOT
  > meet ADR-0022's structured-output bar. It emits NO documented JSON, has no
  > model flag, and is self-described as "an agent-managed museum exhibit rather
  > than a production tool." Under ADR-0022's tiered support it is added
  > BEST-EFFORT only: `parse` surfaces the RAW stdout as `:result` and extracts
  > NOTHING else — no cost, no tokens, no touched-files. Use it for a demo, not a
  > budgeted production run.

  Because claw emits no machine-parseable structure, this profile diverges from
  its siblings at the parse boundary: where Codex/opencode decode an event stream
  and Antigravity decodes a JSON envelope, claw's "structured" output is simply
  the raw text it printed. The parser therefore does no decoding at all — it hands
  the raw stdout back as `:result` and lets the budget's token dimension fall back
  to an estimate (ADR-0008), since there is no usage to report.

  Auth is via env API keys (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`), supplied by
  the operator's environment (forwarded via the CliAdapter's `opts[:env]`, T8.8) —
  not a profile concern. claw has no model flag, so the profile carries no
  `:model` opt and `build_args` ignores `opts` entirely.

  Both functions are PURE; `System.cmd` lives in the CliAdapter.

  **Cannot honor a `max_tokens` budget (T48.5, ADR-0058 §4).** Because every
  dispatch reports no usage at all, a goal's `[budget] max_tokens` ceiling can
  never bind against claw — the loop's token total simply never grows. `Kazi.Loop`
  warns once per run and flags the run's `usage_fidelity` as `:unreported`
  (surfaced on `Kazi.Loop.snapshot/1`, the terminal result, and the additive
  `usage_fidelity` key on `kazi apply --json`) rather than silently letting the
  ceiling sit unenforced. Bound a claw-driven goal on `max_iterations` or
  `max_wall_clock_ms` instead.

  ## argv assembly

    * `prompt <text>` — claw's only non-interactive invocation. There is no JSON
      flag and no model flag, so the argv is always exactly `["prompt", prompt]`.

  ## "Result" shape this parser keys off (there is none)

  claw prints raw text to stdout with no envelope. `parse` is the BEST-EFFORT
  identity: the raw stdout becomes `:result` verbatim (with NO cost/token
  fabrication). Empty stdout yields `%{}` so the CliAdapter keeps its base map and
  the budget estimates rather than recording an empty "answer".
  """

  # =============================================================================
  # argv assembly (contract: docs/devlog.md 2026-06-23, ADR-0022; best-effort)
  # =============================================================================

  @doc """
  Renders the args AFTER the `claw` command for `prompt`.

  Always exactly `["prompt", prompt]` — claw's only non-interactive shape. It has
  no JSON flag and no model flag, so `opts` is intentionally IGNORED (there is
  nothing optional to forward).
  """
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) when is_binary(prompt) and is_list(opts) do
    ["prompt", prompt]
  end

  # =============================================================================
  # raw-stdout parsing (BEST-EFFORT: claw emits no JSON — raw text is the "result")
  # =============================================================================

  @doc """
  Parses claw's raw stdout into the additive subset of the result map. BEST-EFFORT
  and total: claw emits NO structured output, so the raw stdout is surfaced
  verbatim as `:result` with NO invented cost or token counts.

  Empty (or whitespace-only) stdout yields `%{}` — the CliAdapter keeps its base
  map and the budget's token dimension falls back to an estimate (ADR-0008) rather
  than recording an empty answer.
  """
  @spec parse(String.t()) :: map()
  def parse(output) when is_binary(output) do
    if String.trim(output) == "" do
      %{}
    else
      %{result: output}
    end
  end
end
