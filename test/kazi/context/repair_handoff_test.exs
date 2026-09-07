defmodule Kazi.Context.RepairHandoffTest do
  use ExUnit.Case, async: true
  alias Kazi.Context.{RepairHandoff, StuckBundle}
  @moduletag :tmp_dir
  test "immutable full contract and inaccessible reference diagnostics", %{tmp_dir: root} do
    goal =
      Kazi.Goal.new("repair", description: String.duplicate("mandatory requirement 雪\n", 1000))

    initial =
      RepairHandoff.start(goal, root, %{transcript_path: Path.join(root, "sink/transcript.jsonl")})

    assert initial.contract.status == "available"
    assert File.read!(initial.contract.path) =~ goal.description
    File.rm!(initial.contract.path)
    handoff = RepairHandoff.finish(initial, root, :max_total_dispatches, 2, ["code"], [], %{})
    assert handoff["contract"]["status"] == "unavailable"
    assert handoff["total_dispatches"] == 2
  end

  test "candidate identity includes every untracked file", %{tmp_dir: root} do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: root)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.test",
          "commit",
          "--allow-empty",
          "-qm",
          "base"
        ], cd: root)

    for n <- 1..70,
        do:
          File.write!(
            Path.join(root, "file-#{String.pad_leading(to_string(n), 3, "0")}"),
            "before"
          )

    before = RepairHandoff.identity(root)
    File.write!(Path.join(root, "file-070"), "after")
    refute RepairHandoff.identity(root)["patch_sha256"] == before["patch_sha256"]
  end

  test "multibyte evidence fits deterministically and preserves handoff when space permits" do
    input = %{
      failing: [{"code", %{output: String.duplicate("雪", 3000)}}],
      handoff: %{
        "total_dispatches" => 2,
        "contract" => %{"path" => nil, "status" => "unavailable"}
      }
    }

    for budget <- [0, 20, 200, 1000] do
      bundle = StuckBundle.assemble(input, budget: budget)
      assert String.valid?(StuckBundle.render(bundle))
      assert byte_size(StuckBundle.render(bundle)) <= budget
      assert bundle == StuckBundle.assemble(input, budget: budget)
    end

    assert StuckBundle.assemble(input, budget: 1000)["handoff"]["total_dispatches"] == 2
  end
end
