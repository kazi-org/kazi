defmodule Kazi.Teach.DefaultTierTest do
  @moduledoc """
  Sonnet-default tiering flip (task/sonnet-default-tier-flip, ADR-0035
  amendment 2026-07-08): fleet data across ~100 finished runs showed
  `claude-haiku-4-5` stuck+over_budget on ~37% of non-trivial slices vs ~13%
  for `claude-sonnet-5`, a net cost LOSS once escalation is priced in. This
  pins the repo-side tiering guidance (the rendered SKILL.md and `AGENTS.md`)
  to the corrected default: `claude-sonnet-5` is the DEFAULT grind tier,
  `claude-haiku-4-5` is demoted to an explicit opt-down for known-trivial
  slices only, and the escalation ladder is `claude-sonnet-5 -> claude-opus-4-8`.

  Both surfaces must AGREE (coherence across SKILL.md and AGENTS.md) and every
  Claude model id either document names must be a real, currently-priced id
  (`Kazi.Economy.PriceMap`, the same table the run-end KPIs cost against).
  """
  use ExUnit.Case, async: true

  alias Kazi.Economy.PriceMap
  alias Kazi.Teach.InstallSkill

  @skill_md InstallSkill.skill_md()
  @agents_md File.read!("AGENTS.md")

  # A token shaped like a Claude model id -- mirrors the JS tiering-coherence
  # gate's pattern (.github/scripts/check-tiering-coherence.mjs) so both guards
  # extract the same tokens from the same surfaces.
  @model_id_re ~r/\bclaude-(?:opus|sonnet|haiku|fable|mythos|instant)-[0-9][0-9a-z.@-]*/

  defp model_ids(doc), do: @model_id_re |> Regex.scan(doc) |> Enum.map(&hd/1) |> Enum.uniq()

  describe "claude-sonnet-5 is the DEFAULT grind tier" do
    test "the rendered SKILL.md names claude-sonnet-5 as the default grind tier" do
      assert @skill_md =~ "The default tier is `claude-sonnet-5`"

      assert @skill_md =~
               ~r/kazi apply --harness claude --model\s+claude-sonnet-5\s+--json \[--stream\]/
    end

    test "AGENTS.md names claude-sonnet-5 as the default grind tier" do
      assert @agents_md =~ ~r/grind on the DEFAULT grind tier --\s*\n?\s*`?claude-sonnet-5/
    end

    test "the SKILL.md's worked converge example (Step 3) runs on claude-sonnet-5" do
      assert @skill_md =~
               "kazi apply <proposal-ref> --workspace <path> --harness claude --model claude-sonnet-5 --json"
    end

    test "AGENTS.md's worked converge example (step 3) runs on claude-sonnet-5" do
      assert @agents_md =~
               "kazi apply <proposal-ref> --workspace <path> --harness claude --model claude-sonnet-5 --json"
    end

    test "the escalation ladder starts at claude-sonnet-5 and stops at claude-opus-4-8" do
      assert @skill_md =~
               "claude-sonnet-5  ->  claude-opus-4-8   (STOP; do not escalate past Opus)"

      assert @agents_md =~
               "claude-sonnet-5  ->  claude-opus-4-8   (STOP; do not escalate past Opus)"

      # The old three-rung ladder starting on Haiku must be GONE, not just
      # supplemented -- this is the flip, not an addition.
      refute @skill_md =~ "claude-haiku-4-5  ->  claude-sonnet-5  ->  claude-opus-4-8"
      refute @agents_md =~ "claude-haiku-4-5  ->  claude-sonnet-5  ->  claude-opus-4-8"
    end
  end

  describe "claude-haiku-4-5 is demoted to an explicit opt-down, never the default" do
    test "the SKILL.md frames Haiku as an OPT-DOWN for known-trivial slices" do
      assert @skill_md =~ "OPT-DOWN"
      assert @skill_md =~ ~r/explicit OPT-DOWN/
      assert @skill_md =~ ~r/claude-haiku-4-5`\s+is NOT a rung on this\s+ladder/
    end

    test "AGENTS.md frames Haiku as an OPT-DOWN for known-trivial slices" do
      assert @agents_md =~ "OPT-DOWN"
      assert @agents_md =~ ~r/claude-haiku-4-5`\s+is NOT a rung on this\s+ladder/
    end

    test "neither surface teaches haiku-first (no bare 'grind on Haiku' framing)" do
      refute @skill_md =~ "The cheap tier is\n    `claude-haiku-4-5`"
      refute @agents_md =~ "grind on a CHEAP Claude model -- `claude-haiku-4-5`"
    end
  end

  describe "SKILL.md <-> AGENTS.md coherence on the tiering flip" do
    test "both surfaces ground the rationale in live economy + the ADR amendment (#958)" do
      # The dated fleet figures live ONLY in ADR-0035's amendment; the teaching
      # surfaces must point at re-derivable evidence instead of frozen prose.
      for doc <- [@skill_md, @agents_md] do
        assert doc =~ "kazi economy --json"
        assert doc =~ ~r/ADR-0035's (dated )?amendment/
      end
    end

    test "both surfaces reference the ADR-0035 amendment" do
      assert @skill_md =~ ~r/0035, amended\s+2026-07-08/
      assert @agents_md =~ ~r/0035, amended\s+2026-07-08/
    end
  end

  describe "every referenced Claude model id is real and currently priced" do
    test "the SKILL.md references only known model ids" do
      ids = model_ids(@skill_md)
      assert ids != [], "extraction found no model ids -- the regex may be broken"

      unknown = Enum.reject(ids, &PriceMap.known?/1)

      assert unknown == [],
             "SKILL.md references model id(s) not in Kazi.Economy.PriceMap: #{inspect(unknown)}"
    end

    test "AGENTS.md references only known model ids" do
      ids = model_ids(@agents_md)
      assert ids != [], "extraction found no model ids -- the regex may be broken"

      unknown = Enum.reject(ids, &PriceMap.known?/1)

      assert unknown == [],
             "AGENTS.md references model id(s) not in Kazi.Economy.PriceMap: #{inspect(unknown)}"
    end

    test "both surfaces reference claude-sonnet-5, claude-opus-4-8, and claude-haiku-4-5" do
      for doc <- [@skill_md, @agents_md] do
        ids = model_ids(doc)
        assert "claude-sonnet-5" in ids
        assert "claude-opus-4-8" in ids
        assert "claude-haiku-4-5" in ids
      end
    end
  end

  describe "the tiering rationale points at live economy, not a frozen snapshot (#958)" do
    test "both surfaces tell the reader to re-derive tiering from kazi economy" do
      assert @skill_md =~ "kazi economy --json"
      assert @agents_md =~ "kazi economy --json"
    end

    test "neither surface bakes the dated fleet snapshot into its prose" do
      # The dated figure belongs ONLY in ADR-0035's amendment; skill/AGENTS.md
      # must point at `kazi economy` instead (kazi issue #958).
      refute @skill_md =~ "~100 finished runs"
      refute @agents_md =~ "~100 finished runs"
    end
  end

  describe "the apply safety refusals are taught (#955)" do
    test "the rendered SKILL.md teaches both refusal flags and the worktree remedy" do
      assert @skill_md =~ "--allow-primary-workspace"
      assert @skill_md =~ "--allow-duplicate-run"
      assert @skill_md =~ "git worktree add"
    end

    test "AGENTS.md teaches both refusal flags and the worktree remedy" do
      assert @agents_md =~ "--allow-primary-workspace"
      assert @agents_md =~ "--allow-duplicate-run"
      assert @agents_md =~ "git worktree add"
    end

    test "both surfaces warn against reflexively overriding the refusals" do
      # The doc-side half of #955: the failure mode is an agent adding the
      # flag that makes the error go away, defeating the protection.
      assert @skill_md =~ ~r/do (?:NOT|not) reflexively/i
      assert @agents_md =~ ~r/do not reflexively/i
    end
  end

  describe "the ADR-0031 subsumption claim is current (#957)" do
    test "the rendered SKILL.md no longer frames apply's subsumption as coming" do
      refute @skill_md =~ "(coming)"
      refute @skill_md =~ "it is COMING"
    end

    test "the proven claim carries the open #936 wave-checkpoint caveat" do
      assert @skill_md =~ "#936"
      assert @skill_md =~ ~r/no\s+supervised\s+checkpoint\s+between\s+waves/i
    end
  end
end
