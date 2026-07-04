defmodule Kazi.Goal.LoaderAtomSafetyTest do
  @moduledoc """
  M3 (deep-review-001): `Loader.from_map/1` never calls the unbounded
  `String.to_atom/1` on untrusted predicate-config keys. An unknown key is
  rejected as a load error (not silently accepted, and never minted as a fresh
  atom) — so a hallucinating inner agent or an inline-goal MCP caller cannot
  exhaust the BEAM atom table by feeding candidate predicates with novel config
  keys.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader

  defp goal(predicate_overrides) do
    %{
      "id" => "g",
      "name" => "g",
      "predicate" => [
        Map.merge(%{"id" => "p", "provider" => "custom_script"}, predicate_overrides)
      ]
    }
  end

  test "a known config key loads fine and is atomized" do
    assert {:ok, g} =
             Loader.from_map(goal(%{"cmd" => "sh", "args" => ["-c", "true"]}))

    [predicate] = g.predicates
    assert predicate.config[:cmd] == "sh"
    assert predicate.config[:args] == ["-c", "true"]
  end

  test "an unknown config key is a load error, not a crash" do
    assert {:error, reason} =
             Loader.from_map(
               goal(%{
                 "cmd" => "sh",
                 "args" => ["-c", "true"],
                 "this_key_has_never_existed_anywhere_xyz123" => "junk"
               })
             )

    assert reason =~ "unknown config key"
  end

  test "an unknown key never mints a new atom in the atom table" do
    junk_key = "kazi_m3_atom_safety_probe_#{System.unique_integer([:positive])}"

    assert {:error, _reason} =
             Loader.from_map(goal(%{"cmd" => "sh", "args" => ["-c", "true"], junk_key => "x"}))

    assert_raise ArgumentError, fn -> String.to_existing_atom(junk_key) end
  end

  test "many distinct unknown keys across many load attempts still never mint atoms" do
    before_count = :erlang.system_info(:atom_count)

    for n <- 1..200 do
      key = "kazi_m3_atom_safety_bulk_probe_#{n}_#{System.unique_integer([:positive])}"

      assert {:error, _reason} =
               Loader.from_map(goal(%{"cmd" => "sh", "args" => ["-c", "true"], key => "x"}))
    end

    after_count = :erlang.system_info(:atom_count)

    # A handful of atoms may be created by test/ExUnit machinery itself between
    # the two snapshots; the important invariant is that it is NOT ~200 (one per
    # rejected junk key), which would indicate the loader is still atomizing
    # unknown keys.
    assert after_count - before_count < 50
  end
end
