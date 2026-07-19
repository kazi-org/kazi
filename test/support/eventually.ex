defmodule Kazi.TestSupport.Eventually do
  @moduledoc """
  Issue #1013 (T53.4): a small poll helper for integration assertions on
  projections that are best-effort / async relative to `Kazi.CLI.run/2`
  returning (e.g. the read-model registry writes composed onto
  `Kazi.Runtime`'s `on_iteration` seam). Retrying the read closes the gap
  between "the run is done" and "every best-effort projection it fired has
  landed" without weakening what is actually asserted.
  """

  @doc """
  Calls `fun` (assumed to raise via `ExUnit.Assertions` on failure, e.g. an
  `assert`) up to `attempts` times, sleeping `interval_ms` between tries.
  Returns `fun`'s result on the first success; re-raises the last failure once
  `attempts` is exhausted.
  """
  @spec eventually((-> result), non_neg_integer(), non_neg_integer()) :: result
        when result: term()
  def eventually(fun, attempts \\ 20, interval_ms \\ 50) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      if attempts > 1 do
        Process.sleep(interval_ms)
        eventually(fun, attempts - 1, interval_ms)
      else
        reraise error, __STACKTRACE__
      end
  end
end
