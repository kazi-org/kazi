defmodule Kazi.TestSupport.SessionLivenessStub do
  @moduledoc """
  Deterministic session-liveness source for dashboard tests: no `ps` calls.
  A pid string starting with `"dead"` is a closed session; anything else is
  live. Test seeds default to a live pid so state-rendering tests are
  unaffected by the CURRENT/CLOSED scope split; scope tests seed `"dead-*"`
  pids to land runs in the CLOSED scope.
  """

  def alive_map(pids) do
    pids
    |> Enum.filter(&is_binary/1)
    |> Map.new(&{&1, not String.starts_with?(&1, "dead")})
  end
end
