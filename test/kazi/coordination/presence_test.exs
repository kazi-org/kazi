defmodule Kazi.Coordination.PresenceTest do
  @moduledoc """
  Presence + work-intent aggregation over the transport seam (T3.1c; UC-013).

  The acceptance bar: two in-memory doubles publishing presence/intent yield a
  MERGED snapshot listing both; stale entries age out on the INJECTABLE clock;
  hermetic via the in-memory transport (no NATS server, no network). Every call
  pins `:now_ms` to a virtual clock so TTL boundaries are exact.
  """

  use ExUnit.Case, async: true

  alias Kazi.Coordination.Presence
  alias Kazi.Coordination.Presence.Snapshot
  alias Kazi.Coordination.Transport.Memory

  setup do
    {:ok, bus} = Memory.start_link()
    # The shared per-call opts every double publishes through and the aggregator
    # reads through — one bus, two instances announcing onto it.
    {:ok, bus: bus, base: [transport: Memory, bus: bus]}
  end

  defp at(base, now_ms), do: Keyword.put(base, :now_ms, now_ms)

  describe "merged snapshot (two doubles)" do
    test "presence from two instances merges into one snapshot listing both",
         %{base: base} do
      :ok = Presence.announce_presence("instance-a", at(base, 0))
      :ok = Presence.announce_presence("instance-b", at(base, 0))

      assert {:ok, %Snapshot{present: present}} = Presence.snapshot(at(base, 100))

      assert [
               %{instance: "instance-a", announced_at_ms: 0},
               %{instance: "instance-b", announced_at_ms: 0}
             ] = present
    end

    test "per-resource work-intent from two instances merges, listing both",
         %{base: base} do
      :ok = Presence.announce_intent("instance-a", "lib/a.ex", at(base, 0))
      :ok = Presence.announce_intent("instance-b", "lib/b.ex", at(base, 0))

      assert {:ok, %Snapshot{intents: intents}} = Presence.snapshot(at(base, 100))

      assert [
               %{instance: "instance-a", resource: "lib/a.ex"},
               %{instance: "instance-b", resource: "lib/b.ex"}
             ] = intents
    end

    test "the snapshot carries both presence and intent together", %{base: base} do
      :ok = Presence.announce_presence("instance-a", at(base, 0))
      :ok = Presence.announce_intent("instance-a", "lib/a.ex", at(base, 0))
      :ok = Presence.announce_presence("instance-b", at(base, 0))

      assert {:ok, %Snapshot{present: present, intents: intents}} =
               Presence.snapshot(at(base, 100))

      assert ["instance-a", "instance-b"] = Enum.map(present, & &1.instance)
      assert [%{instance: "instance-a", resource: "lib/a.ex"}] = intents
    end

    test "an empty bus yields an empty snapshot", %{base: base} do
      assert {:ok, %Snapshot{present: [], intents: []}} = Presence.snapshot(at(base, 0))
    end
  end

  describe "last-writer-wins merge" do
    test "a fresh heartbeat supersedes an instance's older one (level, not edge)",
         %{base: base} do
      :ok = Presence.announce_presence("instance-a", at(base, 0))
      :ok = Presence.announce_presence("instance-a", at(base, 5_000))

      assert {:ok, %Snapshot{present: [%{instance: "instance-a", announced_at_ms: 5_000}]}} =
               Presence.snapshot(at(base, 6_000))
    end

    test "re-announcing the same intent refreshes its timestamp", %{base: base} do
      :ok = Presence.announce_intent("instance-a", "lib/a.ex", at(base, 0))
      :ok = Presence.announce_intent("instance-a", "lib/a.ex", at(base, 5_000))

      assert {:ok, %Snapshot{intents: [%{announced_at_ms: 5_000}]}} =
               Presence.snapshot(at(base, 6_000))
    end
  end

  describe "TTL aging (injected clock)" do
    test "an entry is still live one ms before the TTL boundary", %{base: base} do
      :ok = Presence.announce_presence("instance-a", at(base, 0))

      ttl = Keyword.put(base, :ttl_ms, 1_000)

      assert {:ok, %Snapshot{present: [%{instance: "instance-a"}]}} =
               Presence.snapshot(at(ttl, 999))
    end

    test "an entry ages out exactly at the TTL boundary", %{base: base} do
      :ok = Presence.announce_presence("instance-a", at(base, 0))

      ttl = Keyword.put(base, :ttl_ms, 1_000)
      assert {:ok, %Snapshot{present: []}} = Presence.snapshot(at(ttl, 1_000))
    end

    test "a stale instance drops while a still-beating one remains", %{base: base} do
      ttl = Keyword.put(base, :ttl_ms, 1_000)

      # a beats once at t0; b beats again at t900, refreshing itself.
      :ok = Presence.announce_presence("instance-a", at(base, 0))
      :ok = Presence.announce_presence("instance-b", at(base, 0))
      :ok = Presence.announce_presence("instance-b", at(base, 900))

      # At t1000 a (last beat t0) ages out; b (last beat t900) is still live.
      assert {:ok, %Snapshot{present: [%{instance: "instance-b"}]}} =
               Presence.snapshot(at(ttl, 1_000))
    end

    test "stale intents age out independently of presence", %{base: base} do
      ttl = Keyword.put(base, :ttl_ms, 1_000)

      :ok = Presence.announce_presence("instance-a", at(base, 900))
      :ok = Presence.announce_intent("instance-a", "lib/a.ex", at(base, 0))

      # presence (t900) live at t1000; the intent (t0) has aged out.
      assert {:ok, %Snapshot{present: [%{instance: "instance-a"}], intents: []}} =
               Presence.snapshot(at(ttl, 1_000))
    end
  end

  test "presence defaults to the in-memory transport when none is given", %{bus: bus} do
    # Only :bus + clock — no :transport key — exercises the default-module path.
    opts = [bus: bus, now_ms: 0]
    :ok = Presence.announce_presence("instance-a", opts)

    assert {:ok, %Snapshot{present: [%{instance: "instance-a"}]}} =
             Presence.snapshot(bus: bus, now_ms: 100)
  end
end
