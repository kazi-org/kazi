defmodule Kazi.Coordination.Transport.MemoryTest do
  @moduledoc """
  The in-memory `Kazi.Coordination.Transport` backend (T3.1c).

  These assert the transport contract directly — publish appends, fetch returns
  the backlog oldest-first, subscribe delivers future publishes — since the
  transport has no shared conformance suite of its own (the NATS backend, T3.1b,
  will reuse `Kazi.Coordination.Presence`'s behaviour through this seam). Hermetic:
  in-process Agent bus, no NATS, no network.
  """

  use ExUnit.Case, async: true

  alias Kazi.Coordination.Transport.Memory

  setup do
    {:ok, bus} = Memory.start_link()
    {:ok, bus: bus}
  end

  describe "publish / fetch" do
    test "fetch on a quiet subject is an empty list", %{bus: bus} do
      assert {:ok, []} = Memory.fetch("presence", bus: bus)
    end

    test "publish appends and fetch returns messages oldest-first", %{bus: bus} do
      :ok = Memory.publish("presence", %{instance: "a"}, bus: bus)
      :ok = Memory.publish("presence", %{instance: "b"}, bus: bus)

      assert {:ok, [%{instance: "a"}, %{instance: "b"}]} =
               Memory.fetch("presence", bus: bus)
    end

    test "subjects are isolated from each other", %{bus: bus} do
      :ok = Memory.publish("presence", %{instance: "a"}, bus: bus)
      :ok = Memory.publish("intent", %{resource: "r"}, bus: bus)

      assert {:ok, [%{instance: "a"}]} = Memory.fetch("presence", bus: bus)
      assert {:ok, [%{resource: "r"}]} = Memory.fetch("intent", bus: bus)
    end

    test "distinct buses do not share messages" do
      {:ok, bus1} = Memory.start_link()
      {:ok, bus2} = Memory.start_link()

      :ok = Memory.publish("presence", %{instance: "a"}, bus: bus1)

      assert {:ok, [%{instance: "a"}]} = Memory.fetch("presence", bus: bus1)
      assert {:ok, []} = Memory.fetch("presence", bus: bus2)
    end
  end

  describe "subscribe" do
    test "a subscriber receives future publishes to its subject", %{bus: bus} do
      :ok = Memory.subscribe("presence", bus: bus)
      :ok = Memory.publish("presence", %{instance: "a"}, bus: bus)

      assert_receive {:kazi_transport, "presence", %{instance: "a"}}
    end

    test "a subscriber does not receive publishes to other subjects", %{bus: bus} do
      :ok = Memory.subscribe("presence", bus: bus)
      :ok = Memory.publish("intent", %{resource: "r"}, bus: bus)

      refute_receive {:kazi_transport, _subject, _msg}
    end

    test "subscribe does not replay the existing backlog", %{bus: bus} do
      :ok = Memory.publish("presence", %{instance: "old"}, bus: bus)
      :ok = Memory.subscribe("presence", bus: bus)

      refute_receive {:kazi_transport, "presence", %{instance: "old"}}
    end
  end

  test "a missing :bus handle is a caller error" do
    assert_raise ArgumentError, fn -> Memory.fetch("presence", []) end
  end
end
