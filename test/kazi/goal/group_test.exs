defmodule Kazi.Goal.GroupTest do
  use ExUnit.Case, async: true
  doctest Kazi.Goal.Group

  alias Kazi.Goal.Group

  describe "normalize_id/1" do
    test "collapses case, whitespace, and & into a canonical slug" do
      assert Group.normalize_id("Identity & Access") == "identity-access"
      assert Group.normalize_id("  Sign  Up  ") == "sign-up"
      assert Group.normalize_id("Billing") == "billing"
    end

    test "is idempotent — a canonical slug normalizes to itself" do
      assert Group.normalize_id("identity-access") == "identity-access"
    end

    test "& and the word 'and' converge to the same id" do
      assert Group.normalize_id("Identity & Access") ==
               Group.normalize_id("Identity and Access")
    end
  end

  describe "new/3" do
    test "normalizes the id but keeps the display name verbatim" do
      g = Group.new("Identity & Access", "Identity & Access")
      assert g.id == "identity-access"
      assert g.name == "Identity & Access"
      assert g.parent == nil
      assert g.budget == nil
    end

    test "normalizes a parent reference and stores the budget verbatim" do
      g = Group.new("sign-up", "Sign Up", parent: "Identity & Access", budget: 5)
      assert g.parent == "identity-access"
      assert g.budget == 5
    end
  end
end
