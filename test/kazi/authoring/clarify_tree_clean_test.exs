defmodule Kazi.Authoring.ClarifyTreeCleanTest do
  @moduledoc """
  Regression pin for issue #937 Gap E (T59.10): `Kazi.Authoring.Clarify.gaps/2`'s
  `tree-clean-predicate` floor entry. A drafted `custom_script` predicate whose
  command asserts the WHOLE working tree is clean -- e.g.
  `test -z "$(git status --porcelain)"` -- gives a false-negative verdict when a
  SIBLING goal commits in the same checkout under shared-workspace scheduling
  (#937 comment 2). T54.1 fixed kazi's built-in serial landing gate, but a
  hand-written whole-tree-cleanliness acceptance predicate is still structurally
  unsafe, and nothing warned the author. The floor warns (ADVISORY, never a
  drafting blocker) unless the check is scoped to the goal's own paths.
  """
  use ExUnit.Case, async: true

  alias Kazi.Authoring.Clarify
  alias Kazi.Authoring.Clarify.Question
  alias Kazi.{Goal, Predicate}

  defp custom_script(id, script) do
    Predicate.new(id, :custom_script,
      acceptance?: true,
      config: %{cmd: "sh", args: ["-c", script]}
    )
  end

  defp goal_with(predicates) do
    Goal.new("g", mode: :create, predicates: predicates)
  end

  defp tree_clean_gap(idea, draft) do
    idea |> Clarify.gaps(draft: draft) |> Enum.find(&(&1.id == "tree-clean-predicate"))
  end

  describe "tree-clean-predicate -- fires on an unscoped whole-tree cleanliness check" do
    test "a `test -z $(git status --porcelain)` acceptance predicate is flagged" do
      draft = goal_with([custom_script(:landed, ~s|test -z "$(git status --porcelain)"|)])

      gap = tree_clean_gap("land the widgets feature", draft)

      assert %Question{} = gap
      assert gap.id == "tree-clean-predicate"
      assert gap.prompt =~ "shared-workspace" or gap.prompt =~ "SIBLING"
      assert gap.prompt != ""
    end

    test "the porcelain / short / -s / git diff --quiet forms are all caught" do
      for script <- [
            ~s|test -z "$(git status --porcelain)"|,
            ~s|[ -z "$(git status --short)" ]|,
            ~s|test -z "$(git status -s)"|,
            "git diff --quiet",
            "git diff --exit-code"
          ] do
        draft = goal_with([custom_script(:landed, script)])
        assert tree_clean_gap("land the feature", draft), "expected a gap for #{script}"
      end
    end
  end

  describe "tree-clean-predicate -- suppressed when scoped to the goal's own paths" do
    test "a `-- lib/foo` pathspec suppresses the gap" do
      draft =
        goal_with([custom_script(:landed, ~s|test -z "$(git status --porcelain -- lib/foo)"|)])

      refute tree_clean_gap("land the feature", draft)
    end

    test "a trailing path token on the porcelain flag suppresses the gap" do
      draft =
        goal_with([custom_script(:landed, ~s|test -z "$(git status --porcelain lib/foo)"|)])

      refute tree_clean_gap("land the feature", draft)
    end

    test "a path-scoped `git diff --quiet -- path` suppresses the gap" do
      draft = goal_with([custom_script(:landed, "git diff --quiet -- lib/foo")])

      refute tree_clean_gap("land the feature", draft)
    end
  end

  describe "tree-clean-predicate -- unrelated custom_script commands never trigger it" do
    test "a mix test predicate is not flagged" do
      draft = goal_with([custom_script(:tests, "mix test")])
      refute tree_clean_gap("land the feature", draft)
    end

    test "a git status of a specific path (no whole-tree check) is not flagged" do
      draft = goal_with([custom_script(:check, "git status --porcelain lib/widgets.ex")])
      refute tree_clean_gap("land the feature", draft)
    end

    test "a draft with no custom_script predicates at all is not flagged" do
      draft = goal_with([Predicate.new(:health, :http_probe, acceptance?: true)])
      refute tree_clean_gap("land the feature", draft)
    end
  end

  describe "tree-clean-predicate -- advisory only, never blocks" do
    test "drafting/persisting still succeeds despite the gap" do
      draft = goal_with([custom_script(:landed, ~s|test -z "$(git status --porcelain)"|)])

      gaps = Clarify.gaps("land the feature", draft: draft)
      assert Enum.any?(gaps, &(&1.id == "tree-clean-predicate"))

      # The draft's own predicates are untouched -- purely informational.
      assert Goal.all_predicates(draft) |> length() == 1

      # It folds like any other question.
      block = Clarify.fold_answers(gaps, %{"tree-clean-predicate" => "scope_paths"})
      assert block =~ "Scope the check to the goal's own paths"
    end

    test "gaps/2 called without a draft (pre-draft --strict gate) never inspects predicates" do
      refute "tree-clean-predicate" in Enum.map(Clarify.gaps("land the feature"), & &1.id)
    end
  end

  describe "tree-clean-predicate -- documented in the predicate-authoring docs (ADR-0034)" do
    test "custom-script-provider.md documents the hazard and the safe alternatives" do
      doc = File.read!(Path.join([File.cwd!(), "docs", "custom-script-provider.md"]))

      assert doc =~ "## Authoring hazard: whole-tree cleanliness checks"
      assert doc =~ "git status --porcelain"
      # safe alternative 1: scope to the goal's own paths
      assert doc =~ "git status --porcelain -- lib/foo"
      # safe alternative 2: kazi's identity-based landing gate
      assert doc =~ "identity-based landing gate"
    end
  end
end
