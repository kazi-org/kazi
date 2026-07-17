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
                 "branch_prefix" => "kazi/",
                 "base" => "main",
                 "commit_style" => "conventional"
               }
             })

    assert integration == %{
             mode: :pr,
             branch_prefix: "kazi/",
             base: "main",
             commit_style: "conventional"
           }
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
end
