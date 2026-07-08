defmodule Kazi.Logging.DashboardLogBoundsTest do
  use ExUnit.Case, async: true

  test "logger level is bounded to info or higher in production" do
    # Verify that debug and trace messages are not logged, only info and above
    level = Application.get_env(:logger, :level)
    assert level in [:info, :warning, :error]
  end
end
