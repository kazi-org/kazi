defmodule Kazi.SessionLivenessTest do
  # The real `ps`-backed probe (the dashboard uses the injectable stub; this
  # exercises the production module). No test can assume a live agent-session
  # ancestor in CI, so assertions stick to the negative invariants: dead or
  # non-session pids are never "alive", and nothing here raises.
  use ExUnit.Case, async: true

  alias Kazi.SessionLiveness

  test "alive?/1 is false for nil, empty, dead, and non-session pids" do
    refute SessionLiveness.alive?(nil)
    refute SessionLiveness.alive?("")
    # An almost-certainly-unused pid.
    refute SessionLiveness.alive?("99999999")
    # This BEAM process is alive but is not an agent-session command.
    refute SessionLiveness.alive?(System.pid())
  end

  test "alive_map/1 maps every input pid and never raises" do
    map = SessionLiveness.alive_map(["99999999", System.pid(), nil, "", "not-a-pid"])
    assert map["99999999"] == false
    assert map[System.pid()] == false
    refute Map.has_key?(map, nil)
    refute Map.has_key?(map, "not-a-pid")
  end

  test "find_session_pid/0 returns nil or a numeric pid string, never raises" do
    case SessionLiveness.find_session_pid() do
      nil -> :ok
      pid -> assert pid =~ ~r/^\d+$/
    end
  end
end
