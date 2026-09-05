defmodule Kazi.Goal.ScopeSharedPathsTest do
  @moduledoc """
  T73.1 (ADR-0087 decision 4): `[scope].shared_paths` — hotspot files a goal
  touches that should NOT count as a blast-radius overlap with other goals or
  fleet members. Covers only the schema/loading half (the loader parses the
  field into `Kazi.Scope`, and an absent declaration is byte-identical to
  today's behavior); the fleet-level union lives in
  `test/kazi/fleet/shared_paths_test.exs`, and the T73.2 exclusion behavior is
  out of scope here.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader

  describe "Kazi.Goal.Loader parses [scope].shared_paths" do
    test "parses into Kazi.Scope" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "scope" => %{"shared_paths" => ["mix.exs"]},
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.shared_paths == ["mix.exs"]
    end

    test "absent shared_paths keeps today's behavior byte-identical" do
      assert {:ok, %Goal{scope: without}} =
               Loader.from_map(%{
                 "id" => "g",
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert {:ok, %Goal{scope: with_write_paths}} =
               Loader.from_map(%{
                 "id" => "g",
                 "scope" => %{"write_paths" => ["a/**"]},
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      # A goal with no [scope] table at all, and one with an unrelated field
      # declared, both default shared_paths to [] — no field, no change.
      assert without.shared_paths == []
      assert with_write_paths.shared_paths == []
    end

    test "a non-list shared_paths is a validation error" do
      assert {:error, msg} =
               Loader.from_map(%{"id" => "g", "scope" => %{"shared_paths" => "not-a-list"}})

      assert msg =~ "scope"
    end
  end
end
