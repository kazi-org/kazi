defmodule Kazi.Authoring.ClarifyLandingTest do
  @moduledoc """
  T44.12 (ADR-0055): `Kazi.Authoring.Clarify.gaps/2`'s `landing` floor entry.

  "Landing is part of convergence" — a CODE goal with no `[integration]` block
  converges and then stops, leaving the change on a branch nobody asked for. The
  floor surfaces that as a gap in the proposal's `clarify` array, by the same
  mechanism as the missing-live-target flag: named, never silently accepted.

  The suppression cases matter as much as the flag. An `integration` block of ANY
  mode answers the question — `"none"` is a deliberate converge-and-stop choice,
  not an omission — and a goal with nothing to land (live probes only) is never
  asked.
  """
  use ExUnit.Case, async: true

  alias Kazi.Authoring.Clarify
  alias Kazi.{Goal, Predicate}

  # A caller-drafts proposal map (ADR-0023): string-keyed, the shape `kazi plan
  # --predicates` accepts and the floor actually runs against.
  defp draft(predicates, extra \\ %{}) do
    Map.merge(%{"predicates" => predicates}, extra)
  end

  defp code_predicates, do: [%{"id" => "tests", "provider" => "test_runner"}]

  defp landing(draft), do: Clarify.gaps("build a feature", draft: draft) |> find_landing()
  defp find_landing(questions), do: Enum.find(questions, &(&1.id == "landing"))

  describe "the gap fires when converged work would have nowhere to go" do
    test "a code draft with no integration block carries a landing clarify entry" do
      assert %{id: "landing"} = q = landing(draft(code_predicates()))

      # The recommendation is actionable, not a shrug.
      assert q.recommended == "pr"
      assert Enum.any?(q.options, &(&1.value == "pr"))
    end

    test "the entry names the gap and its consequence, not just 'missing block'" do
      q = landing(draft(code_predicates()))

      assert q.prompt =~ "[integration]"
      # The WHY: an author who does not know what a missing block costs cannot
      # judge the question.
      assert q.prompt =~ "converges and stops"
    end

    test "the entry suggests the three Wave B gate providers" do
      q = landing(draft(code_predicates()))

      for gate <- ~w(no_stubs oss_hygiene docs_updated) do
        assert q.prompt =~ gate, "the landing suggestion should name the #{gate} gate"
      end
    end

    test "every landing mode is offered" do
      values = landing(draft(code_predicates())).options |> Enum.map(& &1.value)
      assert Enum.sort(values) == ~w(branch commit merge none pr)
    end
  end

  describe "suppression — the gap must not nag" do
    test "an integration block of any mode suppresses it" do
      for mode <- ~w(pr commit branch merge) do
        refute landing(draft(code_predicates(), %{"integration" => %{"mode" => mode}})),
               "mode #{mode} answers the question; asking again is noise"
      end
    end

    # The one that would be easy to get wrong: "none" is an ANSWER (converge and
    # stop deliberately), not an omission. Treating it as unanswered would nag an
    # author who already decided.
    test "integration mode \"none\" suppresses it — a deliberate answer, not a gap" do
      refute landing(draft(code_predicates(), %{"integration" => %{"mode" => "none"}}))
    end

    test "a draft with nothing to land is never asked" do
      # Live probes produce no diff, so there is no work to land.
      refute landing(draft([%{"id" => "up", "provider" => "http_probe"}]))
      refute landing(draft([%{"id" => "logs", "provider" => "prod_log"}]))
    end

    test "an empty or absent draft is never asked" do
      # Pre-draft, predicates are the harness's choice — this gap is draft-derived,
      # so it cannot participate in the pre-draft --strict refusal.
      refute landing(draft([]))
      refute Clarify.gaps("build a feature") |> find_landing()
    end

    # Issue #1277: a real `%Kazi.Goal{}` draft (the shape `kazi plan --json`'s
    # `clarify` array runs over — `Kazi.CLI.clarify_json/1` passes `draft.goal`)
    # ALWAYS suppresses the landing question, because a Goal struct cannot
    # distinguish "declared none" from "never asked" (its default is mode :none), so
    # `draft_has_integration?/1` treats ANY Goal as already-answered. This is what
    # makes a code-predicate check on a `%Kazi.Goal{}` unreachable dead code — the
    # `or` short-circuits before it. Pinning it here so the removed clause stays gone.
    test "a real %Kazi.Goal{} draft (with code predicates) suppresses it" do
      goal = Goal.new("g", predicates: [Predicate.new(:code, :tests)])

      refute Clarify.gaps("build a feature", draft: goal) |> find_landing()
    end
  end

  describe "it composes with the rest of the floor" do
    test "a fully-specified code draft still carries only the landing gap" do
      # An idea naming a live target and a scope, drafted with a live predicate:
      # every other floor entry is satisfied, so `landing` is what remains.
      d =
        draft(
          [
            %{"id" => "tests", "provider" => "test_runner"},
            %{"id" => "live", "provider" => "http_probe"}
          ],
          %{}
        )

      ids =
        Clarify.gaps("only add a /healthz endpoint returning 200 at https://app.test", draft: d)
        |> Enum.map(& &1.id)

      assert "landing" in ids
      refute "live-target" in ids
      refute "scope" in ids
    end
  end
end
