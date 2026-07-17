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

  test "the router recognizes the four sub-skill verbs and maps each to a real CLI verb",
       %{dir: dir} do
    assert {:ok, path} = InstallSkill.write(dir: dir)
    content = File.read!(path)

    # T26.1 (ADR-0031/0032): the router recognizes plan/apply/status/adopt and
    # routes each to the matching PRIMARY CLI command. The verb<->command map row
    # for each must appear, and the CLI verb it routes to must be referenced.
    skill_to_cli = [
      {"plan", "kazi plan"},
      {"apply", "kazi apply"},
      {"status", "kazi status"},
      {"adopt", "kazi init"}
    ]

    for {verb, cli} <- skill_to_cli do
      assert content =~ "`#{verb}`",
             "router SKILL.md does not recognize the `#{verb}` sub-skill verb"

      assert content =~ cli,
             "router SKILL.md does not route `#{verb}` to `#{cli}`"
    end

    # `adopt` is the one human alias (-> kazi init); the other three are identities
    # after ADR-0032. The old run/propose aliases were REMOVED in v0.6.0 (T27.9):
    # the SKILL must say so, and must NOT teach the command forms `` `kazi run` ``
    # / `` `kazi propose` `` (the backticked code references the coherence guard
    # scans). Narrative prose like "have kazi run the loop" is fine.
    assert content =~ "REMOVED" or content =~ "removed in v0.6.0"
    refute content =~ "`kazi run`"
    refute content =~ "`kazi propose`"
  end

  test "a non-kazi repo degrades cleanly WITHOUT naming operator-local skills", %{dir: dir} do
    assert {:ok, path} = InstallSkill.write(dir: dir)
    content = File.read!(path)

    # ADR-0031 consequences: the skill must not hardcode a kazi-only assumption —
    # when `kazi` is not on PATH the agent falls back to its OWN workflow.
    assert content =~ "Degrade cleanly"
    assert content =~ "planning/execution workflow"

    # ADR-0074: the shipped skill is SELF-CONTAINED. kazi cannot assume any
    # operator-local skill exists, so no rendered document may reference one
    # (slash-skill references like `/plan`, `/apply`, `/claim`, `/tidy`,
    # `/loop`, `/qualify` were the leak this ADR removed). A slash-skill
    # reference starts the token (start-of-text, whitespace, backtick, or
    # punctuation before the slash); prose like the "plan/apply with kazi"
    # trigger phrase or a path like docs/plan.md is not one.
    for {name, doc} <- InstallSkill.docs(),
        local_skill <- ~w(plan apply claim tidy loop qualify) do
      refute doc =~ ~r{(?<![A-Za-z0-9])/#{local_skill}\b},
             "#{name} references operator-local skill /#{local_skill} (ADR-0074 forbids it)"
    end
  end

  test "writes AUTHORING.md and RECIPES.md alongside SKILL.md (ADR-0074)", %{dir: dir} do
    assert {:ok, _} = InstallSkill.write(dir: dir)

    for {name, content} <- InstallSkill.docs() do
      path = Path.join(dir, name)
      assert File.exists?(path), "expected #{name} to be written"
      assert File.read!(path) == content
    end

    # The SKILL.md entry point tells the agent where the other two live.
    skill = File.read!(Path.join(dir, "SKILL.md"))
    assert skill =~ "AUTHORING.md"
    assert skill =~ "RECIPES.md"
  end

  test "never writes LOCAL.md, and re-installs preserve an existing one", %{dir: dir} do
    # ADR-0074: LOCAL.md is operator-owned site wiring. install never creates it...
    assert {:ok, _} = InstallSkill.write(dir: dir)
    local = Path.join(dir, InstallSkill.local_file())
    refute File.exists?(local)

    # ...and never overwrites one the operator wrote.
    operator_content = "# my site wiring\nplan-driven work goes through my own orchestrator\n"
    File.write!(local, operator_content)
    assert {:ok, _} = InstallSkill.write(dir: dir)
    assert File.read!(local) == operator_content

    # The SKILL.md teaches the agent to read it when present.
    assert File.read!(Path.join(dir, "SKILL.md")) =~ "LOCAL.md"
  end

  test "the body references the primary recipe verbs and the result contract", %{dir: dir} do
    assert {:ok, path} = InstallSkill.write(dir: dir)
    content = File.read!(path)

    # The plan → approve → apply recipe (the primary CLI verbs, ADR-0032).
    assert content =~ "kazi plan --json"
    assert content =~ "kazi approve <proposal-ref> --json"
    assert content =~ "kazi apply"
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

    # Authoring depth is the default (operator request 2026-07-09). ADR-0074
    # moved the guidance into AUTHORING.md; the SKILL.md must mandate reading it
    # before drafting, and the reference must carry the depth rules.
    assert content =~ "read kazi/AUTHORING.md"
    authoring = InstallSkill.authoring_md()
    assert authoring =~ "Author for the grind tier"
    assert authoring =~ "ONE requirement per predicate"
  end

  test "no document names a command kazi does not have (drift guard)" do
    # The real command surface (from Kazi.CLI's table). The docs may reference a
    # subset; they must NEVER reference a `kazi <word>` that is not one of these.
    # `apply`/`plan` are the primary verbs; `run`/`propose` remain as deprecated
    # aliases (ADR-0032) so the router may name them when flagging the deprecation.
    # `mcp` is the installed MCP-server verb (T33.1, ADR-0044). `economy` is the
    # run-economics report (ADR-0058), `context` the context-store verbs
    # (ADR-0045), `memory` the recall/harvest verbs (ADR-0062/0063). `dashboard` is
    # the standalone fleet-mode web endpoint (T46.4, ADR-0057). `install-hooks` is
    # the opt-in session-bus delivery installer (T55.2, ADR-0071).
    real =
      MapSet.new(~w(apply run plan propose status init install-skill install-hooks list-proposed
                         approve reject export lint help schema version mcp economy context memory
                         dashboard daemon bus))

    # ADR-0074: every rendered document is held to the same guard.
    for {name, content} <- InstallSkill.docs() do
      referenced =
        Regex.scan(~r/`kazi ([a-z][a-z-]*)/, content)
        |> Enum.map(fn [_, cmd] -> cmd end)
        |> MapSet.new()

      bogus = MapSet.difference(referenced, real)

      assert MapSet.size(bogus) == 0,
             "#{name} references non-existent kazi command(s): #{inspect(bogus)}"
    end
  end

  test "is overwrite-stable: re-running rewrites the same paths", %{dir: dir} do
    assert {:ok, path1} = InstallSkill.write(dir: dir)
    assert {:ok, path2} = InstallSkill.write(dir: dir)
    assert path1 == path2
    # Exactly the managed documents -- no strays, and LOCAL.md is never minted.
    assert length(Path.wildcard(Path.join(dir, "**/*.md"))) == length(InstallSkill.docs())
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
