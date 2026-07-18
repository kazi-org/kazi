defmodule Kazi.Bus.ProtocolSkewTest do
  @moduledoc """
  T58.2 (#1227): pure classification of a `ping` reply's `bus_vsn` against
  this client's required protocol level.
  """
  use ExUnit.Case, async: true

  alias Kazi.Bus.ProtocolSkew

  test "a daemon reporting the required bus_vsn classifies as :ok" do
    assert ProtocolSkew.classify(%{"bus_vsn" => ProtocolSkew.required_bus_vsn()}) == :ok
  end

  test "a daemon reporting a NEWER bus_vsn than required still classifies as :ok" do
    assert ProtocolSkew.classify(%{"bus_vsn" => ProtocolSkew.required_bus_vsn() + 1}) == :ok
  end

  test "a daemon reporting an OLDER bus_vsn classifies as :daemon_outdated" do
    assert ProtocolSkew.classify(%{"bus_vsn" => 0}) == :daemon_outdated
  end

  test "a pre-T58.2 daemon that never sends bus_vsn at all classifies as :daemon_outdated" do
    # This is the ORIGINAL #1227 symptom: an old daemon's ping reply has no
    # bus_vsn field because it was compiled before this handshake existed.
    pong = %{"ok" => true, "vsn" => "1.150.0", "pid" => 123}

    assert ProtocolSkew.classify(pong) == :daemon_outdated
  end

  test "a non-integer bus_vsn (malformed reply) classifies as :daemon_outdated, never crashes" do
    assert ProtocolSkew.classify(%{"bus_vsn" => "not-a-version"}) == :daemon_outdated
  end
end
