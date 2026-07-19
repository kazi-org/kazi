defmodule Kazi.Velocity.TranscriptParserTest do
  @moduledoc """
  T67.3 (ADR-0079): the transcript parser folds JSONL into aggregate counters,
  skips malformed lines (R-E67-1), keeps `reasoning_tokens` honest-unknown
  (ADR-0046), and bridges active-time across incremental cursor chunks.
  """
  use ExUnit.Case, async: true

  alias Kazi.Velocity.{Counters, TranscriptParser}

  @fixtures Path.expand("../../support/fixtures/velocity", __DIR__)

  defp read(name), do: File.read!(Path.join(@fixtures, name))

  describe "parse/2" do
    test "folds a fixture transcript into the expected counters, skipping malformed lines" do
      %{session_uuid: uuid, session_name: name, counters: c} =
        TranscriptParser.parse(read("session_a.jsonl"))

      assert uuid == "sess-aaaa-1111"
      assert name == "kazi-alpha"

      assert c.input_tokens == 300
      assert c.cached_input_tokens == 120
      assert c.cache_write_tokens == 30
      assert c.output_tokens == 110
      # Honest-unknown: the transcript never reports reasoning tokens.
      assert c.reasoning_tokens == nil

      assert c.message_count == 3
      assert c.tool_call_count == 3

      # Gaps 30s + 30s, both under the 300s cap.
      assert c.active_time_s == 60
      assert c.first_observed_at == ~U[2026-07-18 12:00:00Z]
      assert c.last_observed_at == ~U[2026-07-18 12:01:00Z]
    end

    test "an idle gap over the bucket cap does not count as active time" do
      %{counters: c} = TranscriptParser.parse(read("session_b.jsonl"))

      assert c.message_count == 2
      assert c.tool_call_count == 0
      assert c.input_tokens == 5
      # The 10-minute gap exceeds the 300s cap, so no active seconds accrue.
      assert c.active_time_s == 0
    end

    test "an empty chunk yields the zero accumulator, never a crash" do
      assert %{counters: %Counters{} = c, session_uuid: nil} = TranscriptParser.parse("")
      assert c.input_tokens == 0
      assert c.message_count == 0
    end

    test "prev_ts bridges active time so an incremental parse equals a single pass" do
      raw = read("session_a.jsonl")
      lines = String.split(raw, "\n", trim: true)
      {head, tail} = Enum.split(lines, 3)

      first = TranscriptParser.parse(Enum.join(head, "\n"))

      second =
        TranscriptParser.parse(Enum.join(tail, "\n"),
          prev_ts: first.counters.last_observed_at
        )

      merged = Counters.merge(first.counters, second.counters)
      single = TranscriptParser.parse(raw).counters

      assert merged.active_time_s == single.active_time_s
      assert merged.input_tokens == single.input_tokens
      assert merged.tool_call_count == single.tool_call_count
    end
  end
end
