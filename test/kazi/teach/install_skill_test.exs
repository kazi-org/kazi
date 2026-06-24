defmodule Kazi.Teach.InstallSkillTest do
  @moduledoc """
  T16.2 (UC-031, ADR-0024 decision 1): `Kazi.Teach.InstallSkill` writes the kazi
  Claude Code SKILL.md.

  HERMETIC: every write targets an INJECTED tmp dir (`:dir`); the real
  `~/.claude` is NEVER touched. The body references only real kazi commands/flags
  (the T16.4 coherence guard enforces this later — pinned here too).
  """
  use ExUnit.Case, async: true

  alias Kazi.Teach.InstallSkill

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-skill-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "writes SKILL.md to the injected dir (never ~/.claude)", %{dir: dir} do
    assert {:ok, path} = InstallSkill.write(dir: dir)
    assert path == Path.join(dir, "SKILL.md")
    assert File.exists?(path)

    # Defensive: the write went to the tmp dir, not the operator's real config.
    refute String.contains?(path, Path.expand("~/.claude"))
  end

  test "the SKILL.md has Claude Code frontmatter (name + description)", %{dir: dir} do
    assert {:ok, path} = InstallSkill.write(dir: dir)
    content = File.read!(path)

    assert String.starts_with?(content, "---\n")
    assert content =~ ~r/\nname: kazi\n/
    assert content =~ ~r/\ndescription: .+\n/
    # The frontmatter block closes before the body.
    assert content =~ ~r/\n---\n/
  end

  test "the body references only real kazi commands and the result contract", %{dir: dir} do
    assert {:ok, path} = InstallSkill.write(dir: dir)
    content = File.read!(path)

    # The propose → approve → run recipe (the three real commands).
    assert content =~ "kazi propose --json"
    assert content =~ "kazi approve <proposal-ref> --json"
    assert content =~ "kazi run"
    # The supporting reads.
    assert content =~ "kazi status <ref> --json"
    assert content =~ "kazi list-proposed --json"
    assert content =~ "kazi help --json"
    assert content =~ "kazi schema"

    # The real flags it teaches.
    assert content =~ "--harness"
    assert content =~ "--model"
    assert content =~ "--predicates"
    assert content =~ "--stream"

    # The result contract the orchestrator branches on.
    assert content =~ "next_action"
    assert content =~ "schema_version"

    # The two-tier economics (the WHY).
    assert content =~ "two-tier"
  end

  test "the body names no command kazi does not have (drift guard)", %{dir: dir} do
    assert {:ok, path} = InstallSkill.write(dir: dir)
    content = File.read!(path)

    # The real command surface (from Kazi.CLI's table). The skill may reference a
    # subset; it must NEVER reference a `kazi <word>` that is not one of these.
    real = MapSet.new(~w(run status init install-skill propose list-proposed approve reject export
                         help schema version))

    referenced =
      Regex.scan(~r/`kazi ([a-z][a-z-]*)/, content)
      |> Enum.map(fn [_, cmd] -> cmd end)
      |> MapSet.new()

    bogus = MapSet.difference(referenced, real)

    assert MapSet.size(bogus) == 0,
           "SKILL.md references non-existent kazi command(s): #{inspect(bogus)}"
  end

  test "is overwrite-stable: re-running rewrites the same path", %{dir: dir} do
    assert {:ok, path1} = InstallSkill.write(dir: dir)
    assert {:ok, path2} = InstallSkill.write(dir: dir)
    assert path1 == path2
    assert length(Path.wildcard(Path.join(dir, "**/*.md"))) == 1
  end

  test "creates the target dir if it does not exist", %{dir: dir} do
    nested = Path.join([dir, "deep", "skills", "kazi"])
    refute File.dir?(nested)
    assert {:ok, path} = InstallSkill.write(dir: nested)
    assert File.exists?(path)
  end

  test "default_dir/0 points under ~/.claude/skills/kazi (not written by this test)" do
    assert InstallSkill.default_dir() ==
             Path.expand(Path.join(["~", ".claude", "skills", "kazi"]))
  end

  test "skill_md/0 returns the same content the writer persists", %{dir: dir} do
    assert {:ok, path} = InstallSkill.write(dir: dir)
    assert File.read!(path) == InstallSkill.skill_md()
  end
end
