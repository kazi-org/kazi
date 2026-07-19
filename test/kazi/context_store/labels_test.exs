defmodule Kazi.ContextStore.LabelsTest do
  use ExUnit.Case, async: true

  alias Kazi.ContextStore.Labels

  doctest Kazi.ContextStore.Labels

  describe "label shapes (ADR-0045 §4)" do
    test "workspace_doc/2 builds the SHA-scoped doc label" do
      assert Labels.workspace_doc("abc123", "docs/concept.md") ==
               "kazi:workspace:abc123:docs:docs/concept.md"
    end

    test "predicate_rationale/2 builds the goal+predicate label" do
      assert Labels.predicate_rationale("g1", "tests_pass") ==
               "kazi:goal:g1:predicate:tests_pass:rationale"
    end

    test "run_test_log/2 builds the goal+iteration test-log label" do
      assert Labels.run_test_log("g1", 3) == "kazi:run:g1:iter:3:test-log"
    end

    test "run_harness_stderr/2 builds the goal+iteration harness-stderr label" do
      assert Labels.run_harness_stderr("g1", 3) == "kazi:run:g1:iter:3:harness-stderr"
    end

    test "stuck_failure_cluster/1 builds the stuck-bundle label" do
      assert Labels.stuck_failure_cluster("g1") == "kazi:run:g1:stuck:failure-cluster"
    end

    test "every label starts with the kazi: prefix" do
      labels = [
        Labels.workspace_doc("sha", "p"),
        Labels.predicate_rationale("g", "p"),
        Labels.run_test_log("g", 0),
        Labels.run_harness_stderr("g", 0),
        Labels.stuck_failure_cluster("g")
      ]

      assert Enum.all?(labels, &String.starts_with?(&1, "kazi:"))
    end
  end

  describe "stability — same input yields the same label" do
    test "workspace_doc/2 is deterministic" do
      assert Labels.workspace_doc("abc123", "docs/a.md") ==
               Labels.workspace_doc("abc123", "docs/a.md")
    end

    test "run_test_log/2 is deterministic" do
      assert Labels.run_test_log("g1", 7) == Labels.run_test_log("g1", 7)
    end

    test "all helpers are pure (repeated calls are equal)" do
      for {fun, args} <- [
            {&Labels.workspace_doc/2, ["sha", "path"]},
            {&Labels.predicate_rationale/2, ["g", "p"]},
            {&Labels.run_test_log/2, ["g", 2]},
            {&Labels.run_harness_stderr/2, ["g", 2]},
            {&Labels.stuck_failure_cluster/1, ["g"]}
          ] do
        assert apply(fun, args) == apply(fun, args)
      end
    end
  end

  describe "SHA-scoping — a changed SHA invalidates the label" do
    test "a different git SHA yields a different workspace_doc label" do
      a = Labels.workspace_doc("sha-old", "docs/a.md")
      b = Labels.workspace_doc("sha-new", "docs/a.md")
      refute a == b
    end

    test "the same SHA + different path yield different labels" do
      refute Labels.workspace_doc("sha", "docs/a.md") ==
               Labels.workspace_doc("sha", "docs/b.md")
    end

    test "a changed iteration yields a different run label" do
      refute Labels.run_test_log("g1", 1) == Labels.run_test_log("g1", 2)
    end

    test "a changed predicate id yields a different rationale label" do
      refute Labels.predicate_rationale("g1", "a") == Labels.predicate_rationale("g1", "b")
    end
  end
end
