defmodule Kazi.Harness.Debrief do
  @moduledoc """
  Post-dispatch debrief capture — the SELF-REPORT (hypothesis) tier of the
  economy feedback loop (T48.11, ADR-0058 §3).

  ADR-0058 ranks prompt-improvement signal in trust order: BEHAVIOR (the
  measured tool/context counters, T48.10) is trusted; SELF-REPORT is a
  hypothesis only, because asking the model "what did you need" is
  confabulation-prone, and handing the answer back into a FUTURE prompt would
  let the inner agent shape its own future instructions — the same gaming-
  channel threat class the diff guard (T32.5) exists to catch.

  So this module is deliberately split into two halves that never call each
  other:

    * `question/0` — rendered into the dispatch prompt (by `Kazi.Loop`) ONLY
      when the goal opted in (`Kazi.Goal.debrief`). Asks for a small, capped,
      structured answer.
    * `extract_from_result/1` (and the lower-level `extract/1`) — reads a
      harness dispatch RESULT's reply text (never a prompt) and returns a
      capped list of hypothesis strings, or `[]` when absent, malformed, or
      the wrong shape.

  **THE HARD RULE (write-only).** Nothing in this module, or anywhere else in
  kazi, may read a persisted hypothesis row back into `question/0` or into any
  other prompt-building function. Hypotheses are a research signal that a
  later BENCHMARK-GATED tool (T48.10/T48.12) may read to propose a prompt/
  context variant — they are never live-wired into what an agent sees. Both
  halves of this module are pure and have no dependency on
  `Kazi.ReadModel.DebriefHypothesis` (the persistence side, wired from
  `Kazi.Runtime`), by construction: there is no function here that reads a
  hypothesis back.
  """

  # T48.11: hard caps enforced regardless of what the model returned, so a
  # runaway or adversarial debrief answer can never inflate the read-model.
  @max_items 10
  @max_item_bytes 500

  @doc "The max number of hypothesis items kept per debrief answer."
  @spec max_items() :: pos_integer()
  def max_items, do: @max_items

  @doc "The max bytes kept per hypothesis item (excess is truncated)."
  @spec max_item_bytes() :: pos_integer()
  def max_item_bytes, do: @max_item_bytes

  @doc """
  The debrief question appended to the dispatch prompt when a goal opts in
  (`[economy] debrief = true`, T48.11). Pure, deterministic text — the SAME
  bytes every dispatch, so it composes cleanly with the prompt-cache stability
  discipline (ADR-0010 §4, T19.2) rather than adding volatility to the prefix.
  """
  @spec question() :: String.t()
  def question do
    """
    ## Debrief (optional, capped)

    Before you finish, list any files or facts you NEEDED but had to discover \
    yourself this iteration (e.g. a file you had to search for, a convention you \
    had to infer) — up to #{@max_items} short items, each under #{@max_item_bytes} \
    bytes. This is a hypothesis for later analysis, not part of your task. End \
    your reply with AT MOST one fenced JSON block in this exact shape (omit it \
    entirely if there is nothing to report):

    ```json
    {"debrief": {"needed_but_discovered": ["<short item>", "..."]}}
    ```
    """
  end

  @doc """
  Extracts a capped list of hypothesis strings from a harness dispatch RESULT
  (never a prompt). Tolerant: an absent, malformed, or wrong-shaped debrief
  block yields `[]` — never an error, never a crash. Accepts the same result
  shapes `Kazi.Loop.Counters.tools/1` does (`{:ok, %{}}` | `{:error, _}` | a
  plain map | anything else).
  """
  @spec extract_from_result(Kazi.HarnessAdapter.result() | map() | term()) :: [String.t()]
  def extract_from_result({:ok, %{} = result}), do: extract_from_result(result)
  def extract_from_result({:error, _}), do: []

  def extract_from_result(%{} = result) do
    text = Map.get(result, :result) || Map.get(result, :output)
    extract(text)
  end

  def extract_from_result(_), do: []

  # Matches a fenced ```json ... ``` block, non-greedy up to the FIRST closing
  # fence — deliberately NOT a brace-balancing match, since the debrief JSON
  # may nest objects/arrays; terminating on the closing ``` (rather than
  # trying to balance `{`/`}`) is what stays correct for nested shapes.
  @fence_regex ~r/```json\s*(.*?)\s*```/s

  @doc """
  Extracts a capped list of hypothesis strings from raw reply TEXT. Scans for
  the LAST fenced ```json block (an agent may have emitted other code in its
  reply), decodes it, and reads `debrief.needed_but_discovered`. Tolerant of
  absence, malformed JSON, or the wrong shape (returns `[]`); ALWAYS caps to
  `max_items/0` items of at most `max_item_bytes/0` redacted bytes, regardless
  of what the model returned.
  """
  @spec extract(String.t() | nil) :: [String.t()]
  def extract(text) when is_binary(text) do
    text
    |> last_json_fence()
    |> decode_debrief()
    |> cap()
  end

  def extract(_), do: []

  defp last_json_fence(text) do
    @fence_regex
    |> Regex.scan(text, capture: :all_but_first)
    |> List.last()
    |> case do
      [json] -> json
      _ -> nil
    end
  end

  defp decode_debrief(nil), do: []

  defp decode_debrief(json) do
    case Jason.decode(json) do
      {:ok, %{"debrief" => %{"needed_but_discovered" => items}}} when is_list(items) ->
        Enum.filter(items, &is_binary/1)

      _ ->
        []
    end
  end

  defp cap(items) do
    items
    |> Enum.take(@max_items)
    |> Enum.map(&Kazi.Redaction.redact/1)
    |> Enum.map(&truncate_bytes(&1, @max_item_bytes))
  end

  # Byte-caps WITHOUT splitting a multi-byte UTF-8 codepoint in half (which
  # would leave an invalid string the DB / JSON re-encoding could choke on).
  defp truncate_bytes(item, max_bytes) when byte_size(item) <= max_bytes, do: item

  defp truncate_bytes(item, max_bytes) do
    item
    |> binary_part(0, max_bytes)
    |> valid_utf8_prefix()
  end

  defp valid_utf8_prefix(<<>>), do: <<>>

  defp valid_utf8_prefix(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end
end
