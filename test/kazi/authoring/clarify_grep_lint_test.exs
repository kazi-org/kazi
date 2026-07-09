defmodule Kazi.Authoring.ClarifyGrepLintTest do
  @moduledoc """
  Regression pin for issue #924: `Kazi.Authoring.Clarify.gaps/2`'s
  `naked-grep-predicate` floor entry. A drafted `custom_script` predicate whose
  whole command is a bare, POSITIVE `grep`/`grep -q`/`grep -rqiE`-style
  text-presence match can pass VACUOUSLY -- string-stuffed into an unrelated
  file, or an accidental match against pre-existing content -- without the
  feature actually being built. The floor warns (ADVISORY, never a drafting
  blocker) unless the draft also carries a companion predicate asserting the
  OLD/stale pattern is ABSENT.
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

  defp naked_grep_gap(idea, draft) do
    idea |> Clarify.gaps(draft: draft) |> Enum.find(&(&1.id == "naked-grep-predicate"))
  end

  describe "naked-grep-predicate -- fires on a vacuous bare grep" do
    test "a draft whose only acceptance is a naked grep -q predicate is flagged" do
      draft = goal_with([custom_script(:check, "grep -q foo lib/widgets.ex")])

      gap = naked_grep_gap("add a widgets feature", draft)

      assert %Question{} = gap
      assert gap.id == "naked-grep-predicate"
      assert is_binary(gap.prompt)
      assert gap.prompt != ""
    end

    test "the naked-grep-predicate/-rq/-rqiE styles are all caught" do
      for script <- [
            "grep -q foo lib/widgets.ex",
            "grep -rq foo lib",
            "grep -rqiE 'foo|bar' lib"
          ] do
        draft = goal_with([custom_script(:check, script)])
        assert naked_grep_gap("add a widgets feature", draft), "expected a gap for #{script}"
      end
    end
  end

  describe "naked-grep-predicate -- suppressed by a companion absence assertion" do
    test "a paired negative-space grep (-qv) suppresses the gap" do
      draft =
        goal_with([
          custom_script(:check, "grep -q foo lib/widgets.ex"),
          custom_script(:no_stub, "grep -qv TODO_STUB lib/widgets.ex")
        ])

      refute naked_grep_gap("add a widgets feature", draft)
    end

    test "a paired `! grep -q` companion suppresses the gap" do
      draft =
        goal_with([
          custom_script(:check, "grep -q foo lib/widgets.ex"),
          custom_script(:no_stub, "! grep -q not_implemented lib/widgets.ex")
        ])

      refute naked_grep_gap("add a widgets feature", draft)
    end

    test "a paired files-without-match (-L) companion suppresses the gap" do
      draft =
        goal_with([
          custom_script(:check, "grep -q foo lib/widgets.ex"),
          custom_script(:no_stub, "grep -L old_impl lib/widgets.ex")
        ])

      refute naked_grep_gap("add a widgets feature", draft)
    end
  end

  describe "naked-grep-predicate -- non-grep custom_script commands never trigger it" do
    test "a mix test predicate is not flagged" do
      draft = goal_with([custom_script(:tests, "mix test")])
      refute naked_grep_gap("add a widgets feature", draft)
    end

    test "a go build predicate is not flagged" do
      draft = goal_with([custom_script(:build, "go build ./...")])
      refute naked_grep_gap("add a widgets feature", draft)
    end

    test "a draft with no custom_script predicates at all is not flagged" do
      draft = goal_with([Predicate.new(:health, :http_probe, acceptance?: true)])
      refute naked_grep_gap("add a widgets feature", draft)
    end

    test "a grep piped into another command is not treated as a bare match" do
      draft = goal_with([custom_script(:check, "grep -c foo lib/widgets.ex | grep -q 1")])
      refute naked_grep_gap("add a widgets feature", draft)
    end
  end

  describe "naked-grep-predicate -- advisory only, never blocks" do
    test "drafting/persisting still succeeds despite the gap" do
      draft = goal_with([custom_script(:check, "grep -q foo lib/widgets.ex")])

      gaps = Clarify.gaps("add a widgets feature", draft: draft)
      assert Enum.any?(gaps, &(&1.id == "naked-grep-predicate"))

      # The draft's own predicates are untouched by the advisory -- the gap is
      # purely informational, not a mutation or a validation failure.
      assert Goal.all_predicates(draft) |> length() == 1

      # It folds like any other question: answering it renders normally rather
      # than raising or short-circuiting the fold.
      block = Clarify.fold_answers(gaps, %{"naked-grep-predicate" => "absence_companion"})
      assert block =~ "Add a companion absence assertion"
    end

    test "gaps/2 called without a draft (pre-draft, e.g. the --strict gate) never inspects predicates" do
      refute "naked-grep-predicate" in Enum.map(Clarify.gaps("add a widgets feature"), & &1.id)
    end
  end
end
