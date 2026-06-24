defmodule Kazi.Goal.GroupLintTest do
  @moduledoc """
  T12.7 (ADR-0020 §Decision 3): the advisory SECOND net — fuzzy-warn on
  near-duplicate group NAMES. The loader's id-uniqueness guard is the first net;
  this catches distinct-id groups whose human NAMES read as an accidental fork.
  """
  use ExUnit.Case, async: true
  doctest Kazi.Goal.GroupLint

  alias Kazi.Goal
  alias Kazi.Goal.{Group, GroupLint}

  defp goal(groups), do: Goal.new("g", groups: groups)

  describe "warnings/1 — near-duplicate NAMES are flagged" do
    test "the canonical &-vs-and drift (distinct ids, near-identical names)" do
      g =
        goal([
          Group.new("identity-access", "Identity & Access"),
          # A different id so the loader's id-uniqueness guard does NOT catch it —
          # exactly the gap the second net exists for.
          Group.new("idaccess", "Identity and Access")
        ])

      assert [warning] = GroupLint.warnings(g)
      assert warning.names == {"Identity & Access", "Identity and Access"}
      assert warning.group_ids == {"identity-access", "idaccess"}
      # normalized-equal → reported with full confidence (1.0).
      assert warning.similarity == 1.0
    end

    test "a punctuation/spacing-only difference normalizes equal and is flagged" do
      g =
        goal([
          Group.new("sign-up", "Sign Up"),
          Group.new("signup", "Sign-Up")
        ])

      assert [warning] = GroupLint.warnings(g)
      assert warning.similarity == 1.0
    end

    test "a one-character typo is caught by the Jaro threshold (not normalized-equal)" do
      g =
        goal([
          Group.new("identity", "Identity"),
          Group.new("identiy", "Identiy")
        ])

      assert [warning] = GroupLint.warnings(g)
      assert warning.names == {"Identity", "Identiy"}
      # A real fuzzy match (below 1.0) above the documented threshold.
      assert warning.similarity >= GroupLint.threshold()
      assert warning.similarity < 1.0
    end

    test "names BOTH groups so the author can find them" do
      g =
        goal([
          Group.new("billing", "Billing & Payments"),
          Group.new("billing-pay", "Billing and Payments")
        ])

      assert [%{group_ids: {"billing", "billing-pay"}, names: {a, b}}] = GroupLint.warnings(g)
      assert a == "Billing & Payments"
      assert b == "Billing and Payments"
    end
  end

  describe "warnings/1 — clearly-distinct or exact names yield NO warning" do
    test "distinct names are silent" do
      g =
        goal([
          Group.new("identity", "Identity"),
          Group.new("billing", "Billing"),
          Group.new("reporting", "Reporting")
        ])

      assert GroupLint.warnings(g) == []
    end

    test "a goal with zero or one group has no pair to compare" do
      assert GroupLint.warnings(goal([])) == []
      assert GroupLint.warnings(goal([Group.new("identity", "Identity")])) == []
    end

    test "short distinct names below the threshold are not flagged" do
      # "Auth" vs "Jobs" share no structure — well below 0.92.
      g =
        goal([
          Group.new("auth", "Auth"),
          Group.new("jobs", "Jobs")
        ])

      assert GroupLint.warnings(g) == []
    end
  end

  describe "warnings/1 — pairing" do
    test "each near-duplicate pair is reported exactly once (unordered, no self-pair)" do
      g =
        goal([
          Group.new("identity-access", "Identity & Access"),
          Group.new("idaccess", "Identity and Access"),
          Group.new("identityaccess", "Identity Access")
        ])

      warnings = GroupLint.warnings(g)
      # 3 mutually-near names → C(3,2) = 3 unordered pairs, each once.
      assert length(warnings) == 3

      pairs = Enum.map(warnings, & &1.group_ids) |> MapSet.new()

      assert pairs ==
               MapSet.new([
                 {"identity-access", "idaccess"},
                 {"identity-access", "identityaccess"},
                 {"idaccess", "identityaccess"}
               ])
    end
  end

  describe "threshold/0" do
    test "is the documented high-precision cutoff" do
      assert GroupLint.threshold() == 0.92
    end
  end
end
