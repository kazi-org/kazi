defmodule Kazi.Velocity.TranscriptParser do
  @moduledoc """
  T67.3 (ADR-0079 decision 2, R-E67-1): folds a chunk of local harness transcript
  JSONL into a `Kazi.Velocity.Counters` accumulator plus the session identity.

  ALL knowledge of the transcript line format lives here (the collector edge). A
  malformed or unrecognised line is SKIPPED, never a crash: a format break degrades
  to "no new counters" for that line, never a wrong number and never an exception
  (R-E67-1). The parser reads ONLY the numeric/timestamp fields it needs; it never
  copies message text, tool `input`, or tool `name` into the accumulator — the
  privacy boundary is upheld at the point of parse, not just at ship.

  Recognised lines (Claude Code / Codex JSONL, harness-agnostic best-effort):

    * `type: "assistant"` — `message.usage` token counts (input / cache-read /
      cache-write / output / reasoning); each `message.content` block whose `type`
      is `"tool_use"` increments the tool-call count; the line counts as one
      message. Its `timestamp` extends the active-time window.
    * `type: "user"` — counts as one message; its `timestamp` extends the window.
    * identity lines (`sessionId`, `agentName`/`agent-name`, `customTitle`) — set
      the session UUID and display name.

  ## Active time

  Active-time seconds accumulate as the sum of inter-event gaps that fall at or
  under `bucket_cap_s` (default #{300}s): a burst of activity counts, an idle gap
  longer than the cap does not (it is "away" time, not work). `prev_ts` seeds the
  first gap so the collector can BRIDGE across incremental cursor chunks — the last
  timestamp of the prior pass is passed in, and the gap from it to this chunk's
  first event is counted (when under the cap) exactly as an intra-chunk gap would
  be. This makes the incremental parse produce the same total as a single pass.
  """

  alias Kazi.Velocity.Counters

  @default_bucket_cap_s 300

  @typedoc "The parse result: the session identity and the chunk's counters."
  @type result :: %{
          session_uuid: String.t() | nil,
          session_name: String.t() | nil,
          counters: Counters.t()
        }

  @doc """
  Parse a chunk of raw transcript bytes (whole JSONL lines).

  Options:

    * `:prev_ts` — the last event timestamp observed by a prior incremental pass,
      seeding the active-time bridge across the cursor. Defaults to `nil`.
    * `:bucket_cap_s` — the active-time gap cap in seconds. Defaults to
      `#{@default_bucket_cap_s}`.
  """
  @spec parse(binary(), keyword()) :: result()
  def parse(raw, opts \\ []) when is_binary(raw) do
    cap = Keyword.get(opts, :bucket_cap_s, @default_bucket_cap_s)
    prev_ts = Keyword.get(opts, :prev_ts)

    acc = %{
      session_uuid: nil,
      session_name: nil,
      counters: %Counters{},
      prev_ts: prev_ts,
      cap: cap
    }

    raw
    |> String.split("\n", trim: true)
    |> Enum.reduce(acc, &fold_line/2)
    |> finish()
  end

  defp finish(acc) do
    %{session_uuid: acc.session_uuid, session_name: acc.session_name, counters: acc.counters}
  end

  # A line that is not valid JSON is skipped (R-E67-1 degrade), never a crash.
  defp fold_line(line, acc) do
    case Jason.decode(line) do
      {:ok, obj} when is_map(obj) -> apply_obj(obj, acc)
      _ -> acc
    end
  end

  defp apply_obj(obj, acc) do
    acc
    |> take_identity(obj)
    |> take_event(obj)
  end

  defp take_identity(acc, obj) do
    %{
      acc
      | session_uuid: acc.session_uuid || string(obj, "sessionId"),
        session_name:
          acc.session_name || string(obj, "agentName") || string(obj, "customTitle") ||
            string(obj, "agent-name")
    }
  end

  defp take_event(acc, %{"type" => "assistant"} = obj) do
    message = Map.get(obj, "message", %{})
    usage = if is_map(message), do: Map.get(message, "usage", %{}), else: %{}
    tool_calls = tool_call_count(message)

    counters =
      acc.counters
      |> add_tokens(usage)
      |> bump(:message_count, 1)
      |> bump(:tool_call_count, tool_calls)

    observe(%{acc | counters: counters}, obj)
  end

  defp take_event(acc, %{"type" => "user"} = obj) do
    counters = bump(acc.counters, :message_count, 1)
    observe(%{acc | counters: counters}, obj)
  end

  defp take_event(acc, _obj), do: acc

  # Extend the active-time window and bucketed active seconds from the line's
  # timestamp. An unparseable/absent timestamp leaves the window untouched.
  defp observe(acc, obj) do
    case timestamp(obj) do
      nil ->
        acc

      ts ->
        counters = window(acc.counters, ts)
        counters = accrue_active(counters, acc.prev_ts, ts, acc.cap)
        %{acc | counters: counters, prev_ts: ts}
    end
  end

  defp window(counters, ts) do
    %{
      counters
      | first_observed_at: min_ts(counters.first_observed_at, ts),
        last_observed_at: max_ts(counters.last_observed_at, ts)
    }
  end

  defp accrue_active(counters, nil, _ts, _cap), do: counters

  defp accrue_active(counters, prev, ts, cap) do
    gap = DateTime.diff(ts, prev, :second)

    if gap > 0 and gap <= cap do
      bump(counters, :active_time_s, gap)
    else
      counters
    end
  end

  # `reasoning_tokens` is honest-unknown: only lift it out of nil when the usage
  # actually reports it, so a transcript that never exposes it stays nil.
  defp add_tokens(counters, usage) when is_map(usage) do
    counters
    |> bump(:input_tokens, int(usage, "input_tokens"))
    |> bump(:cached_input_tokens, int(usage, "cache_read_input_tokens"))
    |> bump(:cache_write_tokens, int(usage, "cache_creation_input_tokens"))
    |> bump(:output_tokens, int(usage, "output_tokens"))
    |> bump_optional(:reasoning_tokens, optional_int(usage, "reasoning_tokens"))
  end

  defp add_tokens(counters, _usage), do: counters

  defp tool_call_count(message) when is_map(message) do
    case Map.get(message, "content") do
      content when is_list(content) ->
        Enum.count(content, fn
          %{"type" => "tool_use"} -> true
          _ -> false
        end)

      _ ->
        0
    end
  end

  defp tool_call_count(_message), do: 0

  defp bump(counters, _field, 0), do: counters
  defp bump(counters, field, n), do: Map.update!(counters, field, &(&1 + n))

  defp bump_optional(counters, _field, nil), do: counters

  defp bump_optional(counters, field, n) do
    Map.update!(counters, field, fn
      nil -> n
      cur -> cur + n
    end)
  end

  defp int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp optional_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp timestamp(obj) do
    with s when is_binary(s) <- Map.get(obj, "timestamp"),
         {:ok, dt, _offset} <- DateTime.from_iso8601(s) do
      dt
    else
      _ -> nil
    end
  end

  defp min_ts(nil, ts), do: ts
  defp min_ts(cur, ts), do: if(DateTime.compare(ts, cur) == :lt, do: ts, else: cur)

  defp max_ts(nil, ts), do: ts
  defp max_ts(cur, ts), do: if(DateTime.compare(ts, cur) == :gt, do: ts, else: cur)
end
