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

  # T49.12: the OTHER side of the same guard. Rejecting unknown keys is only
  # correct if every LEGITIMATE key is interned — otherwise a real, documented
  # config key is rejected as "unknown" and a valid goal-file will not load.
  #
  # A `scenario` predicate passes its non-scenario keys through to the delegate
  # surface (T49.3), so `samples = 3` is legitimate and documented. But the loader
  # interns keys by force-loading the predicate's OWN provider (`:scenario`) and
  # nothing else — and `Kazi.Providers.Scenario` named `:samples` only in a
  # comment, so a monitor goal-file failed to load with:
  #
  #     predicate "signup-still-works" has unknown config key "samples"
  #
  # `mix` HID it: it loads Kazi.Providers.Browser (which names :samples), so the
  # atom happened to exist. This is the same trap as the Gherkin doc-keys
  # (@gherkin_doc_keys, devlog 2026-07-15) — "every test and CI passed while
  # `kazi apply` on the real binary failed".
  describe "release-load safety: a scenario predicate's delegate keys are interned" do
    test "Kazi.Providers.Scenario interns the delegate passthrough keys by itself" do
      # The condition the RELEASE binary actually creates: only the predicate's own
      # provider has been force-loaded. Purge the delegate so a passing result
      # cannot come from Browser having interned the atoms.
      :code.purge(Kazi.Providers.Browser)
      :code.delete(Kazi.Providers.Browser)
      {:module, _} = Code.ensure_loaded(Kazi.Providers.Scenario)

      for key <- Kazi.Providers.Scenario.delegate_passthrough_keys() do
        name = Atom.to_string(key)

        assert String.to_existing_atom(name) == key,
               "#{name} is not interned by Kazi.Providers.Scenario alone — a scenario " <>
                 "goal-file using it will fail to load in the release binary with " <>
                 "\"unknown config key\", even though mix passes"
      end
    after
      Code.ensure_loaded(Kazi.Providers.Browser)
    end

    test "a scenario predicate carrying samples LOADS" do
      goal = %{
        "id" => "monitor",
        "name" => "monitor",
        "predicate" => [
          %{
            "id" => "cap",
            "provider" => "scenario",
            "spec" => "docs/specs/product/x.feature",
            "scenario" => "S",
            "url" => "https://app.example.com",
            "samples" => 3
          }
        ]
      }

      assert {:ok, _} = Loader.from_map(goal)
    end
  end
end
