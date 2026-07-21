defmodule Kazi.Authoring.ClarifySelfHostingTest do
  @moduledoc """
  Regression pin for issue #1668 (T45.10 exit-proof): `Kazi.Authoring.Clarify.gaps/2`'s
  `self-hosting-cli-predicate` floor entry. A drafted `cli`/`custom_script`
  predicate whose `cmd` names the SAME executable the target workspace itself
  builds measures the INSTALLED/last-built binary, not the source tree a fix
  edits -- unsatisfiable by a source change alone until a release happens (the
  live T45.10 proof: `kazi help | grep -c "kazi dashboard"` stayed `0` against
  the installed binary while the SAME edited tree already answered `1` in-process).
  The floor warns (ADVISORY, never a drafting blocker) whenever `:own_binary_name`
  is resolved and a predicate's `cmd` matches it; silent (absent the opt) for
  every ordinary, non-self-hosting workspace.
  """
  use ExUnit.Case, async: true

  alias Kazi.Authoring.Clarify
  alias Kazi.Authoring.Clarify.Question
  alias Kazi.{Goal, Predicate}

  defp cli_predicate(id, cmd) do
    Predicate.new(id, :cli,
      acceptance?: true,
      config: %{cmd: cmd, assertions: [%{"target" => "exit_code", "expected" => 0}]}
    )
  end

  defp custom_script_predicate(id, cmd) do
    Predicate.new(id, :custom_script, acceptance?: true, config: %{cmd: cmd})
  end

  defp goal_with(predicates) do
    Goal.new("g", mode: :create, predicates: predicates)
  end

  defp self_hosting_gap(idea, draft, own_binary_name) do
    idea
    |> Clarify.gaps(draft: draft, own_binary_name: own_binary_name)
    |> Enum.find(&(&1.id == "self-hosting-cli-predicate"))
  end

  describe "self-hosting-cli-predicate -- fires when cmd matches the workspace's own binary" do
    test "a cli predicate shelling out to the workspace's own name is flagged" do
      draft = goal_with([cli_predicate(:help_text, "kazi")])

      gap = self_hosting_gap("fix kazi's own help output", draft, "kazi")

      assert %Question{} = gap
      assert gap.id == "self-hosting-cli-predicate"
      assert gap.prompt =~ "help_text"
      assert gap.prompt =~ "kazi"
      assert gap.prompt =~ "hermetic"
    end

    test "a custom_script predicate shelling out to the workspace's own name is flagged" do
      draft = goal_with([custom_script_predicate(:help_text, "kazi")])

      assert self_hosting_gap("fix kazi's own help output", draft, "kazi")
    end

    test "multiple at-risk predicates are all named" do
      draft =
        goal_with([
          cli_predicate(:one, "kazi"),
          cli_predicate(:two, "kazi"),
          Predicate.new(:unrelated, :http_probe, acceptance?: true)
        ])

      gap = self_hosting_gap("fix kazi", draft, "kazi")

      assert gap.prompt =~ "one"
      assert gap.prompt =~ "two"
    end
  end

  describe "self-hosting-cli-predicate -- silent in the ordinary (non-self-hosting) case" do
    test "absent own_binary_name, the gap never fires even against a matching cmd" do
      draft = goal_with([cli_predicate(:help_text, "kazi")])
      refute self_hosting_gap("fix kazi's own help output", draft, nil)
    end

    test "a cmd that does NOT match the workspace's own binary is not flagged" do
      draft = goal_with([cli_predicate(:deploy, "terraform")])
      refute self_hosting_gap("run terraform", draft, "kazi")
    end

    test "a non-cli/custom_script predicate is never flagged, whatever its config" do
      draft = goal_with([Predicate.new(:health, :http_probe, acceptance?: true)])
      refute self_hosting_gap("ship a health endpoint", draft, "kazi")
    end

    test "a draft with no predicates at all is not flagged" do
      refute self_hosting_gap("an idea", goal_with([]), "kazi")
    end

    test "gaps/2 called without a draft (pre-draft --strict gate) never inspects predicates" do
      refute "self-hosting-cli-predicate" in Enum.map(
               Clarify.gaps("fix kazi", own_binary_name: "kazi"),
               & &1.id
             )
    end
  end

  describe "self-hosting-cli-predicate -- advisory only, never blocks" do
    test "drafting/persisting still succeeds despite the gap" do
      draft = goal_with([cli_predicate(:help_text, "kazi")])

      gaps = Clarify.gaps("fix kazi", draft: draft, own_binary_name: "kazi")
      assert Enum.any?(gaps, &(&1.id == "self-hosting-cli-predicate"))

      # The draft's own predicates are untouched -- purely informational.
      assert Goal.all_predicates(draft) |> length() == 1

      # It folds like any other question.
      block = Clarify.fold_answers(gaps, %{"self-hosting-cli-predicate" => "hermetic_check"})
      assert block =~ "hermetic in-process check"
    end
  end
end
