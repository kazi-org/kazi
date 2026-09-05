defmodule Kazi.CLI.ProjectFlagDocTest do
  @moduledoc """
  T45.2 (UC-059): `--project` is a shared flag with TWO distinct meanings --
  `bus who` (T55.11) filters the presence roster by cwd, while `plan`
  (caller-drafts) instead reads it as a JSON multi-goal roadmap payload
  (`Authoring.propose_roadmap/2`). The `help --json` surface is GENERATED from
  one `@flag_docs` entry shared by both commands (`Kazi.CLI`'s command table),
  so a description written for only one of them silently misdescribes the
  other. This pins:

    * `--project` is listed on BOTH `bus` and `plan` in `help --json` (the
      command table already wires this; this guards against it drifting).
    * the shared description names `plan`, not just `bus who` -- so an agent
      reading `help --json` learns both meanings.
    * the description does not claim the flag is `bus who`-exclusive (no
      "only" qualifier), since that would misdescribe `plan`'s usage.

  HERMETIC: `help --json` is a pure in-process read, no read-model/network.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defp project_flag_doc(command_name) do
    out = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end)
    {:ok, payload} = Jason.decode(String.trim(out))

    command = Enum.find(payload["commands"], &(&1["name"] == command_name))
    flag = Enum.find(command["flags"], &(&1["name"] == "--project"))

    assert flag, "#{command_name} should list --project in help --json"
    flag["description"]
  end

  test "`bus` lists --project" do
    assert is_binary(project_flag_doc("bus"))
  end

  test "`plan` lists --project" do
    assert is_binary(project_flag_doc("plan"))
  end

  test "bus and plan share the same --project description (one generated doc)" do
    assert project_flag_doc("bus") == project_flag_doc("plan")
  end

  test "the shared --project description names `plan`, not just `bus who`" do
    doc = project_flag_doc("bus")
    assert doc =~ "plan"
  end

  test "the shared --project description does not claim it is `bus who`-only" do
    doc = project_flag_doc("bus")
    refute doc =~ "only"
  end
end
