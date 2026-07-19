defmodule Kazi.Velocity.SessionCollectorTest do
  @moduledoc """
  T67.3 (ADR-0079): the collector turns a transcript directory into per-session
  counter rows in the read-model — incrementally (byte cursor), idempotently (a
  re-run emits zero duplicate rows), and only when the machine has OPTED IN.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Kazi.Repo
  alias Kazi.ReadModel.SessionCounters
  alias Kazi.Velocity.SessionCollector

  @fixtures Path.expand("../../support/fixtures/velocity", __DIR__)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    state_dir =
      Path.join(System.tmp_dir!(), "kazi-velocity-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(state_dir) end)
    {:ok, state_dir: state_dir}
  end

  defp rows, do: Repo.all(from(s in SessionCounters, order_by: s.session_uuid))

  defp collect(state_dir) do
    SessionCollector.collect(
      dir: @fixtures,
      state_dir: state_dir,
      machine: "test-host",
      # Best-effort fact ship is exercised elsewhere; here we only assert the row.
      poster: fn _kind, _text, _opts -> :ok end
    )
  end

  describe "collect/1 — counters" do
    test "a fixture directory yields the expected per-session rows", %{state_dir: state_dir} do
      collected = collect(state_dir)
      assert length(collected) == 2

      [a, b] = rows()

      assert a.session_uuid == "sess-aaaa-1111"
      assert a.session_name == "kazi-alpha"
      assert a.machine == "test-host"
      assert a.input_tokens == 300
      assert a.cached_input_tokens == 120
      assert a.cache_write_tokens == 30
      assert a.output_tokens == 110
      assert a.reasoning_tokens == nil
      assert a.message_count == 3
      assert a.tool_call_count == 3
      assert a.active_time_s == 60
      assert a.first_observed_at == ~U[2026-07-18 12:00:00.000000Z]
      assert a.last_observed_at == ~U[2026-07-18 12:01:00.000000Z]

      assert b.session_uuid == "sess-bbbb-2222"
      assert b.input_tokens == 5
      assert b.active_time_s == 0
    end
  end

  describe "collect/1 — idempotency" do
    test "a second run over unchanged transcripts emits zero duplicate rows",
         %{state_dir: state_dir} do
      collect(state_dir)
      first = rows()

      # Re-run with the SAME cursor state dir: nothing has grown.
      collect(state_dir)
      second = rows()

      assert length(second) == length(first)
      assert length(second) == 2

      # Totals are unchanged (last-write-wins upsert on the cumulative counters).
      a_before = Enum.find(first, &(&1.session_uuid == "sess-aaaa-1111"))
      a_after = Enum.find(second, &(&1.session_uuid == "sess-aaaa-1111"))
      assert a_after.input_tokens == a_before.input_tokens
      assert a_after.tool_call_count == a_before.tool_call_count
      assert a_after.active_time_s == a_before.active_time_s
    end

    test "appending new transcript lines accumulates without re-counting the old",
         %{state_dir: state_dir} do
      dir =
        Path.join(System.tmp_dir!(), "kazi-velocity-incr-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "s.jsonl")

      File.write!(path, """
      {"type":"assistant","timestamp":"2026-07-18T12:00:00Z","sessionId":"sess-incr","message":{"role":"assistant","usage":{"input_tokens":10,"output_tokens":5},"content":[]}}
      """)

      SessionCollector.collect(
        dir: dir,
        state_dir: state_dir,
        machine: "test-host",
        poster: fn _, _, _ -> :ok end
      )

      [r1] = Repo.all(from(s in SessionCounters, where: s.session_uuid == "sess-incr"))
      assert r1.input_tokens == 10
      assert r1.message_count == 1

      # Append a second assistant turn.
      File.write!(
        path,
        """
        {"type":"assistant","timestamp":"2026-07-18T12:00:30Z","sessionId":"sess-incr","message":{"role":"assistant","usage":{"input_tokens":20,"output_tokens":7},"content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}
        """,
        [:append]
      )

      SessionCollector.collect(
        dir: dir,
        state_dir: state_dir,
        machine: "test-host",
        poster: fn _, _, _ -> :ok end
      )

      [r2] = Repo.all(from(s in SessionCounters, where: s.session_uuid == "sess-incr"))

      # Cumulative, counted once each: 10+20 in, 1+1 messages, 0+1 tool calls,
      # and the 30s bridge across the cursor.
      assert r2.input_tokens == 30
      assert r2.message_count == 2
      assert r2.tool_call_count == 1
      assert r2.active_time_s == 30
    end
  end

  describe "collect/1 — bounded scan (#1606)" do
    defp incr_dir do
      dir =
        Path.join(System.tmp_dir!(), "kazi-velocity-bound-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    defp line(ts, tokens) do
      ~s({"type":"assistant","timestamp":"#{ts}","sessionId":"sess-bound","message":{"role":"assistant","usage":{"input_tokens":#{tokens},"output_tokens":1},"content":[]}}\n)
    end

    defp collect_bounded(dir, state_dir, max_bytes) do
      SessionCollector.collect(
        dir: dir,
        state_dir: state_dir,
        machine: "test-host",
        max_bytes: max_bytes,
        poster: fn _, _, _ -> :ok end
      )
    end

    defp bound_row do
      Repo.one(from(s in SessionCounters, where: s.session_uuid == "sess-bound"))
    end

    test "a per-pass byte budget advances the cursor in chunks; totals complete over passes",
         %{state_dir: state_dir} do
      dir = incr_dir()
      path = Path.join(dir, "s.jsonl")

      lines =
        line("2026-07-18T12:00:00Z", 10) <>
          line("2026-07-18T12:00:30Z", 20) <> line("2026-07-18T12:01:00Z", 30)

      File.write!(path, lines)

      # A budget just over one line: each pass ingests exactly ONE new line, so a
      # single pass never reads the whole (potentially huge) file — the property
      # that keeps a pass under the ticker deadline on a large tree.
      one_line = byte_size(line("2026-07-18T12:00:00Z", 10))

      collect_bounded(dir, state_dir, one_line + 5)
      assert bound_row().message_count == 1
      assert bound_row().input_tokens == 10

      collect_bounded(dir, state_dir, one_line + 5)
      assert bound_row().message_count == 2

      collect_bounded(dir, state_dir, one_line + 5)
      row = bound_row()
      # All three lines are now counted, each exactly once (cumulative, no double
      # count across the bounded passes).
      assert row.message_count == 3
      assert row.input_tokens == 60
    end

    test "a caught-up transcript is skipped (returns nothing) on the next pass",
         %{state_dir: state_dir} do
      dir = incr_dir()
      path = Path.join(dir, "s.jsonl")
      File.write!(path, line("2026-07-18T12:00:00Z", 10))

      assert [_one] = collect_bounded(dir, state_dir, 8 * 1024 * 1024)
      # Nothing has grown: the second pass stat-skips the file and ships nothing
      # (no re-read, no duplicate ship) — steady-state cost is a stat per file.
      assert collect_bounded(dir, state_dir, 8 * 1024 * 1024) == []
    end
  end

  describe "run/1 — opt-in gate" do
    test "is a no-op and disabled by default" do
      System.delete_env("KAZI_VELOCITY_COLLECTOR")
      refute SessionCollector.enabled?()
      assert SessionCollector.run(dir: @fixtures) == {:ok, :disabled}
      assert rows() == []
    end

    test "runs when explicitly enabled via the env override", %{state_dir: state_dir} do
      System.put_env("KAZI_VELOCITY_COLLECTOR", "1")
      on_exit(fn -> System.delete_env("KAZI_VELOCITY_COLLECTOR") end)

      assert SessionCollector.enabled?()

      assert {:ok, collected} =
               SessionCollector.run(
                 dir: @fixtures,
                 state_dir: state_dir,
                 machine: "test-host",
                 poster: fn _, _, _ -> :ok end
               )

      assert length(collected) == 2
      assert length(rows()) == 2
    end
  end
end
