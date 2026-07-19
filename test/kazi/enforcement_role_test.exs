defmodule Kazi.EnforcementRoleTest do
  # Role-scoped enforcement (T49.6, ADR-0064 d3/d7): the write-disjoint fixer /
  # demonstrator surfaces built on the existing digest-diff lease. Tier 1 (pure
  # path-diff logic over a real temp workspace; no git, no dispatch).
  use ExUnit.Case, async: true

  alias Kazi.Enforcement
  alias Kazi.Goal.Loader

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_roles_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs/specs/pins"))
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, ws: dir}
  end

  @pin "docs/specs/pins/x.pin.json"
  @spec_path "docs/specs/x.feature"
  @code "lib/app.ex"

  defp write!(ws, rel, contents), do: File.write!(Path.join(ws, rel), contents)

  defp role_profile do
    Enforcement.new(
      enabled: true,
      roles: %{
        fixer: %{read_only_paths: [@pin, @spec_path]},
        demonstrator: %{allowed_write_paths: [@pin]}
      }
    )
  end

  describe "for_role/2" do
    test "resolves each role's policy, empty for an unset role" do
      profile = role_profile()
      assert Enforcement.for_role(profile, :fixer) == %{read_only_paths: [@pin, @spec_path]}
      assert Enforcement.for_role(profile, :demonstrator) == %{allowed_write_paths: [@pin]}
      assert Enforcement.for_role(Enforcement.new(), :fixer) == %{}
    end
  end

  describe "fixer role — unchanged read_only lease" do
    test "a write to the pin path is a :read_only_write violation", %{ws: ws} do
      write!(ws, @pin, "{}")
      profile = role_profile()
      before = Enforcement.digest_paths(ws, [@pin, @spec_path])

      write!(ws, @pin, "{\"changed\": true}")

      assert Enforcement.detect_role_writes(profile, :fixer, ws, before) == [
               %{type: :read_only_write, path: @pin}
             ]
    end

    test "a code write (outside read_only_paths) is NOT a violation", %{ws: ws} do
      write!(ws, @pin, "{}")
      profile = role_profile()
      before = Enforcement.digest_paths(ws, [@pin, @spec_path])

      write!(ws, @code, "defmodule App do\nend\n")

      assert Enforcement.detect_role_writes(profile, :fixer, ws, before) == []
    end
  end

  describe "demonstrator role — inverted (write-only) surface" do
    test "a write to the pin path is CLEAN (allowed)", %{ws: ws} do
      profile = role_profile()
      changed = [@pin]
      before = Enforcement.digest_paths(ws, changed)

      write!(ws, @pin, "{\"minted\": true}")

      assert Enforcement.detect_role_writes(profile, :demonstrator, ws, before, changed) == []
    end

    test "a write to lib/ is a :disallowed_write violation (opposite of fixer)", %{ws: ws} do
      profile = role_profile()
      changed = [@pin, @code]
      before = Enforcement.digest_paths(ws, changed)

      write!(ws, @pin, "{\"minted\": true}")
      write!(ws, @code, "defmodule App do\nend\n")

      assert Enforcement.detect_role_writes(profile, :demonstrator, ws, before, changed) == [
               %{type: :disallowed_write, path: @code}
             ]
    end
  end

  describe "with_role_defaults/2" do
    test "derives fixer read-only (specs + pins appended) and demonstrator write-only (pins)" do
      profile = Enforcement.new(enabled: true, read_only_paths: ["config/"])

      derived =
        Enforcement.with_role_defaults(profile, %{specs: [@spec_path], pins: [@pin]})

      assert derived.roles.fixer.read_only_paths == ["config/", @spec_path, @pin]
      assert derived.roles.demonstrator.allowed_write_paths == [@pin]
    end

    test "an explicit roles block wins untouched" do
      profile = Enforcement.new(roles: %{fixer: %{read_only_paths: ["only-this"]}})

      assert Enforcement.with_role_defaults(profile, %{specs: [@spec_path], pins: [@pin]}) ==
               profile
    end

    test "no scenario paths leaves the profile unchanged" do
      profile = Enforcement.new(enabled: true)
      assert Enforcement.with_role_defaults(profile, %{specs: [], pins: []}) == profile
    end
  end

  describe "loader round-trip" do
    defp scenario_predicate(overrides) do
      Map.merge(
        %{
          "id" => "cap",
          "provider" => "scenario",
          "spec" => @spec_path,
          "scenario" => "A user can do the thing",
          "pin" => @pin
        },
        overrides
      )
    end

    test "an explicit [enforcement.roles] block round-trips verbatim" do
      data = %{
        "id" => "g",
        "enforcement" => %{
          "enabled" => true,
          "roles" => %{
            "fixer" => %{"read_only_paths" => ["docs/specs/pins/a.pin.json"]},
            "demonstrator" => %{"allowed_write_paths" => ["docs/specs/pins/a.pin.json"]}
          }
        },
        "predicate" => [%{"id" => "t", "provider" => "test_runner"}]
      }

      assert {:ok, goal} = Loader.from_map(data)

      assert goal.enforcement.roles == %{
               fixer: %{read_only_paths: ["docs/specs/pins/a.pin.json"]},
               demonstrator: %{allowed_write_paths: ["docs/specs/pins/a.pin.json"]}
             }
    end

    test "an ABSENT roles block derives defaults from the scenario predicates" do
      data = %{
        "id" => "g",
        "enforcement" => %{"enabled" => true},
        "predicate" => [scenario_predicate(%{})]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert goal.enforcement.roles.fixer.read_only_paths == [@spec_path, @pin]
      assert goal.enforcement.roles.demonstrator.allowed_write_paths == [@pin]
    end

    test "a scenario goal with NO [enforcement] table still derives roles" do
      data = %{"id" => "g", "predicate" => [scenario_predicate(%{})]}

      assert {:ok, goal} = Loader.from_map(data)
      assert goal.enforcement.roles.demonstrator.allowed_write_paths == [@pin]
    end
  end

  describe "byte-identical regression — no scenario predicates" do
    test "a goal with an [enforcement] table but no scenario predicate has empty roles" do
      data = %{
        "id" => "g",
        "enforcement" => %{"enabled" => true, "read_only_paths" => ["test/"]},
        "predicate" => [%{"id" => "t", "provider" => "test_runner"}]
      }

      assert {:ok, goal} = Loader.from_map(data)
      assert goal.enforcement.roles == %{}
      # Existing enforcement behavior is untouched.
      assert goal.enforcement.read_only_paths == ["test/"]

      assert Enforcement.guarantee_atoms(goal.enforcement) == [
               :clean_tree,
               :fail_on_skip,
               :read_only_lease,
               :separate_process
             ]
    end

    test "a goal with no [enforcement] table and no scenario predicate carries no profile" do
      data = %{"id" => "g", "predicate" => [%{"id" => "t", "provider" => "test_runner"}]}

      assert {:ok, goal} = Loader.from_map(data)
      assert goal.enforcement == nil
    end
  end
end
