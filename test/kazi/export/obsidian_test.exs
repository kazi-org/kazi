defmodule Kazi.Export.ObsidianTest do
  @moduledoc """
  T12.6 (ADR-0020 §Decision 5): `Kazi.Export.Obsidian` renders a goal's group
  tree + predicate verdicts into an Obsidian VAULT — one note per group and per
  predicate, `[[wikilinked]]` parent↔child, tagged by verdict (intended / built /
  pending), an OVERVIEW note carrying the per-group rollups, and a Mermaid rollup
  diagram.

  `render/2` is PURE (a goal + verdicts → a deterministic map of note content);
  only `write/3` touches disk. The file-write test writes to a tmp dir under
  `System.tmp_dir!`, cleaned up `on_exit`, mirroring
  `Kazi.Authoring.RationaleAdrTest`.
  """
  use ExUnit.Case, async: true

  doctest Kazi.Export.Obsidian

  alias Kazi.Export.Obsidian
  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Predicate

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-obsidian-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # A grouped goal mirroring priv/examples/grouped_taxonomy.toml: a pillar
  # (Identity & Access) with a child domain (Sign Up, budget 5), a second pillar
  # (Billing), and predicates referencing groups by normalized id.
  defp grouped_goal do
    Goal.new("grouped-taxonomy-example",
      name: "A goal with a declared group taxonomy",
      groups: [
        Group.new("Identity & Access", "Identity & Access"),
        Group.new("sign-up", "Sign Up", parent: "identity-access", budget: 5),
        Group.new("billing", "Billing")
      ],
      predicates: [
        Predicate.new(:signup_form, :browser,
          description: "the sign-up form submits",
          group: "sign-up"
        ),
        Predicate.new(:identity_health, :http_probe, group: "identity-access"),
        Predicate.new(:invoice, :http_probe, group: "billing")
      ]
    )
  end

  describe "render/2 — the vault is pure + deterministic" do
    test "writes an OVERVIEW note, one note per group, and one per predicate" do
      vault = Obsidian.render(grouped_goal())

      assert Map.has_key?(vault, "OVERVIEW.md")
      # one note per group (3) + one per predicate (3) + OVERVIEW = 7.
      assert map_size(vault) == 7

      for slug <- ~w(identity-access sign-up billing) do
        assert Map.has_key?(vault, "#{slug}.md")
      end

      for pred <- ~w(signup_form identity_health invoice) do
        assert Map.has_key?(vault, "predicate-#{pred}.md")
      end
    end

    test "is deterministic — the same goal + verdicts yield the same vault byte-for-byte" do
      goal = grouped_goal()

      assert Obsidian.render(goal, %{signup_form: true}) ==
               Obsidian.render(goal, %{signup_form: true})
    end

    test "notes link parent↔child via [[wikilinks]]" do
      vault = Obsidian.render(grouped_goal())

      # The parent pillar links DOWN to its child domain.
      assert vault["identity-access.md"] =~ "[[sign-up]]"
      # The child domain links UP to its parent pillar.
      assert vault["sign-up.md"] =~ "[[identity-access]]"
      # A predicate links back UP to its owning group.
      assert vault["predicate-signup_form.md"] =~ "[[sign-up]]"
      # The group lists its own predicate as a [[wikilink]].
      assert vault["sign-up.md"] =~ "[[predicate-signup_form]]"
    end

    test "tags reflect verdicts — pending without a run, built when passing" do
      # No verdicts: every predicate is pending, every non-empty group pending.
      static = Obsidian.render(grouped_goal())
      assert static["predicate-signup_form.md"] =~ "#pending"
      assert static["sign-up.md"] =~ "#pending"

      # With the sign-up predicate passing, its predicate note + its group read built.
      live = Obsidian.render(grouped_goal(), %{signup_form: true})
      assert live["predicate-signup_form.md"] =~ "#built"
      assert live["sign-up.md"] =~ "#built"
      # The pillar still has a pending descendant (identity_health), so it is pending.
      assert live["identity-access.md"] =~ "#pending"
    end

    test "a group with no predicates in scope is tagged #intended" do
      goal =
        Goal.new("g",
          groups: [Group.new("empty", "Empty Pillar")],
          predicates: [Predicate.new(:p1, :tests)]
        )

      vault = Obsidian.render(goal)
      assert vault["empty.md"] =~ "#intended"
    end

    test "the OVERVIEW note carries the per-group rollup table" do
      overview = Obsidian.render(grouped_goal(), %{signup_form: true})["OVERVIEW.md"]

      assert overview =~ "## Per-group rollup"
      assert overview =~ "| group | intended | built | pending |"
      # identity-access rolls up its own predicate + the sign-up child: 2 intended,
      # 1 built (signup_form), 1 pending (identity_health).
      assert overview =~ "[[identity-access]] | 2 | 1 | 1"
      # sign-up: 1 intended, 1 built, 0 pending.
      assert overview =~ "[[sign-up]] | 1 | 1 | 0"
    end

    test "the OVERVIEW note emits a Mermaid rollup diagram of the tree" do
      overview = Obsidian.render(grouped_goal(), %{signup_form: true})["OVERVIEW.md"]

      assert overview =~ "```mermaid"
      assert overview =~ "graph TD"
      # A node per group, labelled with built/intended, and a parent→child edge.
      assert overview =~ ~s|g_identity_access["Identity & Access (1/2)"]|
      assert overview =~ ~s|g_sign_up["Sign Up (1/1)"]|
      assert overview =~ "g_identity_access --> g_sign_up"
    end

    test "a flat goal (no groups) still renders — OVERVIEW + ungrouped predicate notes" do
      goal = Goal.new("flat", predicates: [Predicate.new(:p1, :tests)])
      vault = Obsidian.render(goal)

      assert Map.has_key?(vault, "OVERVIEW.md")
      assert Map.has_key?(vault, "predicate-p1.md")
      assert vault["OVERVIEW.md"] =~ "(no groups declared)"
      # The predicate is ungrouped.
      assert vault["predicate-p1.md"] =~ "(ungrouped)"
    end
  end

  describe "write/3 — the only I/O" do
    test "writes the rendered vault to the target dir", %{dir: dir} do
      assert {:ok, %{dir: ^dir, notes: notes}} = Obsidian.write(grouped_goal(), dir)

      assert File.dir?(dir)
      assert File.exists?(Path.join(dir, "OVERVIEW.md"))
      assert File.exists?(Path.join(dir, "sign-up.md"))
      assert File.exists?(Path.join(dir, "predicate-signup_form.md"))
      assert length(notes) == 7

      # The written content matches the pure render (write is render + file I/O).
      assert File.read!(Path.join(dir, "sign-up.md")) ==
               Obsidian.render(grouped_goal())["sign-up.md"]
    end

    test "colours the vault with supplied verdicts", %{dir: dir} do
      assert {:ok, _} = Obsidian.write(grouped_goal(), dir, verdicts: %{signup_form: true})
      assert File.read!(Path.join(dir, "predicate-signup_form.md")) =~ "#built"
    end
  end
end
