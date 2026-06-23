defmodule Kazi.Authoring.ClarifyTest do
  @moduledoc """
  T11.1/T11.2 (UC-029, ADR-0019): the pure clarify core. The deterministic
  gap-detection floor (`gaps/2`) and `fold_answers/2` are pure -- no I/O, no
  harness -- so they are tested directly here.
  """
  use ExUnit.Case, async: true

  alias Kazi.Authoring.Clarify
  alias Kazi.Authoring.Clarify.{Option, Question}
  alias Kazi.{Goal, Predicate}

  doctest Kazi.Authoring.Clarify.Option
  doctest Kazi.Authoring.Clarify.Question

  describe "gaps/2 -- deterministic floor" do
    test "an idea with no live target yields a live-verification question" do
      ids = "add a widgets feature" |> Clarify.gaps() |> Enum.map(& &1.id)
      assert "live-target" in ids

      live = Enum.find(Clarify.gaps("add a widgets feature"), &(&1.id == "live-target"))
      assert live.recommended == "http_probe"
      assert Enum.map(live.options, & &1.value) == ["http_probe", "prod_log", "tests_only"]
    end

    test "an idea naming an HTTP endpoint without a status yields a status/auth question" do
      ids = "expose a /healthz endpoint" |> Clarify.gaps() |> Enum.map(& &1.id)
      assert "http-status" in ids

      q = Enum.find(Clarify.gaps("expose a /healthz endpoint"), &(&1.id == "http-status"))
      assert q.allow_free_text
    end

    test "an endpoint idea that already pins a status code asks no http-status question" do
      ids = "GET /healthz must return 200 on https://app.example.com" |> Clarify.gaps()
      ids = Enum.map(ids, & &1.id)
      refute "http-status" in ids
    end

    test "a fully-specified idea yields zero floor questions" do
      idea =
        "GET /healthz returns 200 with no auth on https://app.example.com; " <>
          "scope: that endpoint only, no deploy"

      assert Clarify.gaps(idea) == []
    end

    test "a draft that already carries a live predicate suppresses the live-target question" do
      goal =
        Goal.new("g",
          mode: :create,
          predicates: [Predicate.new(:health, :http_probe, acceptance?: true)]
        )

      idea = "add a widgets feature"
      assert Enum.any?(Clarify.gaps(idea), &(&1.id == "live-target"))
      refute Enum.any?(Clarify.gaps(idea, draft: goal), &(&1.id == "live-target"))
    end

    test "a proposal map with a prod_log predicate suppresses the live-target question" do
      draft = %{"predicates" => [%{"id" => "x", "provider" => "prod_log"}]}
      refute Enum.any?(Clarify.gaps("add a feature", draft: draft), &(&1.id == "live-target"))
    end

    test "an explicit scope statement suppresses the scope question" do
      assert Enum.any?(Clarify.gaps("build a thing"), &(&1.id == "scope"))
      refute Enum.any?(Clarify.gaps("build a thing, scope: just the core"), &(&1.id == "scope"))
    end

    test "is deterministic -- same idea yields the same questions" do
      assert Clarify.gaps("add a widgets feature") == Clarify.gaps("add a widgets feature")
    end
  end

  describe "fold_answers/2" do
    setup do
      questions = [
        Question.new("live-target", "What is the live-verification target?",
          options: [
            Option.new("A deployed URL", "http_probe"),
            Option.new("Production logs", "prod_log")
          ]
        ),
        Question.new("scope", "What is in scope?",
          options: [Option.new("Just the core change", "core")]
        )
      ]

      {:ok, questions: questions}
    end

    test "renders answered questions as a stable block, resolving option labels", %{
      questions: questions
    } do
      block = Clarify.fold_answers(questions, %{"live-target" => "http_probe", "scope" => "core"})

      assert block ==
               """
               Clarifications provided by the author:
               - What is the live-verification target? -> A deployed URL
               - What is in scope? -> Just the core change\
               """
    end

    test "skips unanswered and blank answers", %{questions: questions} do
      block = Clarify.fold_answers(questions, %{"live-target" => "prod_log", "scope" => ""})

      assert block ==
               "Clarifications provided by the author:\n- What is the live-verification target? -> Production logs"
    end

    test "passes free-text answers through verbatim", %{questions: questions} do
      block = Clarify.fold_answers(questions, %{"scope" => "core plus a migration"})
      assert block =~ "What is in scope? -> core plus a migration"
    end

    test "returns an empty string when nothing is answered", %{questions: questions} do
      assert Clarify.fold_answers(questions, %{}) == ""
    end

    test "is deterministic -- same answers yield the same block", %{questions: questions} do
      answers = %{"live-target" => "http_probe", "scope" => "core"}
      assert Clarify.fold_answers(questions, answers) == Clarify.fold_answers(questions, answers)
    end
  end
end
