defmodule KaziWeb.DagLiveStandaloneMaintenanceTest do
  @moduledoc """
  Regression checker for the standalone-dashboard maintenance-tickers gap:
  `Kazi.ReadModel.RunReaperTicker` (T48.15/#916) and
  `Kazi.Logging.DashboardLogRotation` previously lived only in
  `Kazi.Application`'s child list. The Burrito binary's standalone entry
  (`running_standalone?/0`) hands off to `Kazi.CLI` before that supervision
  tree ever starts, and `kazi dashboard` instead boots ONLY
  `Kazi.CLI.standalone_dashboard_children/0` -- so under the actual released
  deployment mode, neither ticker ever ran. Live-verified: a synthetic zombie
  run (dead os_pid, stale heartbeat) sat unreaped across multiple 5-minute
  ticker intervals against a running `kazi dashboard` process.

  This is a sibling to `dag_live_standalone_test.exs` (issue #801's read-only
  acceptance checker) rather than an edit to it -- that file documents it must
  not be modified.
  """
  use ExUnit.Case, async: false

  describe "standalone dashboard tree includes the periodic maintenance children" do
    test "standalone_dashboard_children/0 lists the run reaper ticker and log rotation" do
      children = Kazi.CLI.standalone_dashboard_children()

      assert Enum.member?(children, Kazi.ReadModel.RunReaperTicker),
             "standalone children must include Kazi.ReadModel.RunReaperTicker so zombie runs are reaped under `kazi dashboard`"

      assert Enum.member?(children, Kazi.Logging.DashboardLogRotation),
             "standalone children must include Kazi.Logging.DashboardLogRotation so dashboard.log is bounded under `kazi dashboard`"
    end
  end
end
