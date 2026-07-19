defmodule Kazi.ReadModel.RunRegistryReadGuardTest do
  @moduledoc """
  Pins the #1483 reopened fix: `RunRegistry.list/0` is the FIRST call
  `MissionControlLive.assign_fleet/1` makes on every mount and every 2s poll
  tick, so it must never block the whole (single-process) LiveView the way a
  raw, unguarded `Repo.all/2` can under fleet write contention. Same
  no-sandbox-checkout technique as `HeartbeatTickerTest`'s "read-model
  degrade" describe (issue #1511): in manual Sandbox mode a Repo call with no
  owned connection raises, which `Guard.run/3` converts to the same
  `{:error, :read_model_unavailable}` tuple a real 15s timeout would produce
  -- deterministic and fast, no need to actually wedge SQLite for 60s.
  """
  use ExUnit.Case, async: true

  alias Kazi.ReadModel.RunRegistry

  test "an unavailable read-model degrades list/0 to an empty list, not a raise or a hang" do
    assert RunRegistry.list() == []
  end
end
