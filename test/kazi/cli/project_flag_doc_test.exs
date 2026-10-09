defmodule Kazi.CLI.ProjectFlagDocTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "plan documents the roadmap payload" do
    output = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end)
    plan = Enum.find(Jason.decode!(output)["commands"], &(&1["name"] == "plan"))
    project = Enum.find(plan["flags"], &(&1["name"] == "--project"))
    assert project["description"] =~ "multi-goal roadmap"
  end
end
