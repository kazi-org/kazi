defmodule Kazi.Teach.SkillCoversCommandsTest do
  @moduledoc """
  Issue #974: `kazi help --json` lists `lint`, `dashboard`, `export`, and
  `economy --rediscovery` as real, shipped commands, but the rendered SKILL.md
  never mentioned them, so an orchestrating agent driving kazi never learned
  they exist. This pins each mention at its natural point in the recipe (see
  `Kazi.Teach.InstallSkill.skill_md/0`) rather than as a bolted-on appendix.
  """
  use ExUnit.Case, async: true

  test "the rendered SKILL.md mentions lint, dashboard, export, and economy --rediscovery" do
    skill_md = Kazi.Teach.InstallSkill.skill_md()

    assert skill_md =~ "kazi lint"
    assert skill_md =~ "kazi dashboard"
    assert skill_md =~ "kazi export"
    assert skill_md =~ "economy --rediscovery"
  end
end
