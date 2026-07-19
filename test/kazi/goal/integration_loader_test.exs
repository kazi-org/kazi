defmodule Kazi.Goal.IntegrationLoaderTest do
  @moduledoc """
  T44.1 (ADR-0055): the loader maps the optional `[integration]` table onto
  `Goal.integration`. Absent, or `mode = "none"`, resolves to
  `Kazi.Goal.default_integration/0` — byte-identical to a goal-file authored with
  no `[integration]` block at all.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader

  defp base_data(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "g",
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      },
      extra
    )
  end

  defp load(extra), do: Loader.from_map(base_data(extra))

  test "no [integration] table -> the default (mode :none) block" do
    assert {:ok, %Goal{integration: integration}} = Loader.from_map(base_data())
    assert integration == Goal.default_integration()
    assert integration.mode == :none
  end

  test "each of the five modes loads and exposes its atom" do
    for {str, atom} <- [
          {"commit", :commit},
          {"branch", :branch},
          {"pr", :pr},
          {"merge", :merge},
          {"none", :none}
        ] do
      assert {:ok, %Goal{integration: %{mode: ^atom}}} =
               load(%{"integration" => %{"mode" => str}})
    end
  end

  test "mode = \"none\" (alone) is byte-identical to an absent block" do
    {:ok, absent} = Loader.from_map(base_data())
    {:ok, explicit} = load(%{"integration" => %{"mode" => "none"}})
    assert explicit.integration == absent.integration
    assert explicit == absent
  end

  test "an empty [integration] table defaults to mode :none" do
    assert {:ok, %Goal{integration: %{mode: :none}}} = load(%{"integration" => %{}})
    {:ok, absent} = Loader.from_map(base_data())
    {:ok, empty} = load(%{"integration" => %{}})
    assert empty == absent
  end

  test "the optional string fields are stored verbatim" do
    assert {:ok, %Goal{integration: integration}} =
             load(%{
               "integration" => %{
                 "mode" => "pr",
                 "branch" => "task/ship-it",
                 "branch_prefix" => "kazi/",
                 "base" => "main",
                 "commit_style" => "conventional"
               }
             })

    assert integration == %{
             mode: :pr,
             branch: "task/ship-it",
             branch_prefix: "kazi/",
             base: "main",
             commit_style: "conventional"
           }
  end

  test "an authored branch is stored verbatim; absent it stays nil (derived later)" do
    assert {:ok, %Goal{integration: %{branch: "release/x"}}} =
             load(%{"integration" => %{"mode" => "branch", "branch" => "release/x"}})

    assert {:ok, %Goal{integration: %{branch: nil}}} =
             load(%{"integration" => %{"mode" => "branch"}})
  end

  test "a non-string branch is a load error naming the field" do
    assert {:error, reason} =
             load(%{"integration" => %{"mode" => "branch", "branch" => 7}})

    assert reason =~ "integration.branch"
  end

  test "an unknown mode is a load error naming the field and the value" do
    assert {:error, reason} = load(%{"integration" => %{"mode" => "rebase"}})
    assert reason =~ "[integration]"
    assert reason =~ "mode"
    assert reason =~ "rebase"
  end

  test "a non-string mode is a load error" do
    assert {:error, reason} = load(%{"integration" => %{"mode" => 3}})
    assert reason =~ "[integration]"
    assert reason =~ "mode"
    assert reason =~ "string"
  end

  test "a non-string branch_prefix is a load error naming the field" do
    assert {:error, reason} =
             load(%{"integration" => %{"mode" => "branch", "branch_prefix" => 7}})

    assert reason =~ "integration.branch_prefix"
  end

  test "a non-table [integration] is a load error" do
    assert {:error, reason} = load(%{"integration" => "oops"})
    assert reason =~ "[integration]"
  end

  # ===========================================================================
  # T44.2 (ADR-0055): the loader synthesizes a `landed` predicate when the goal
  # declares a landing mode, and NONE when it does not.
  # ===========================================================================

  describe "landed-predicate synthesis (T44.2)" do
    test "mode = \"none\" (and an absent block) synthesizes NO landed predicate" do
      # Regression pin: default behavior must be byte-identical to pre-T44.2.
      {:ok, absent} = Loader.from_map(base_data())
      {:ok, explicit_none} = load(%{"integration" => %{"mode" => "none"}})

      refute Enum.any?(absent.predicates, &(&1.kind == :landed))
      refute Enum.any?(explicit_none.predicates, &(&1.kind == :landed))
      # The whole struct is unchanged — no predicate appended, nothing reordered.
      assert explicit_none == absent
    end

    test "each landing mode appends exactly one visible, non-guard landed predicate" do
      for {str, atom} <- [
            {"commit", :commit},
            {"branch", :branch},
            {"pr", :pr},
            {"merge", :merge}
          ] do
        {:ok, goal} = load(%{"integration" => %{"mode" => str}})
        landed = Enum.filter(goal.predicates, &(&1.kind == :landed))

        assert [%Kazi.Predicate{} = p] = landed
        assert p.id == :landed
        assert p.config.mode == atom
        # Visible + non-guard is the working-tree-evaluation invariant (L-0024):
        # a guard/held-out landed would grade from a frozen clean ref and pass off
        # a stranded fix.
        refute p.guard?
        refute p.held_out?
      end
    end

    test "the synthesized landed predicate carries the derived target branch" do
      {:ok, derived} = load(%{"id" => "widgets", "integration" => %{"mode" => "commit"}})
      p = Enum.find(derived.predicates, &(&1.kind == :landed))
      assert p.config.branch == "task/widgets"

      {:ok, authored} =
        load(%{"integration" => %{"mode" => "commit", "branch" => "release/x"}})

      p2 = Enum.find(authored.predicates, &(&1.kind == :landed))
      assert p2.config.branch == "release/x"
    end

    test "the authored predicates are preserved; landed is appended, not substituted" do
      {:ok, goal} = load(%{"integration" => %{"mode" => "commit"}})
      kinds = Enum.map(goal.predicates, & &1.kind)
      # The authored `test_runner` predicate (base_data/1) is still present.
      assert :tests in kinds
      assert :landed in kinds
      assert List.last(goal.predicates).kind == :landed
    end
  end
end
