defmodule Kazi.HarnessTest do
  @moduledoc """
  Unit tests for the harness resolution seam `Kazi.Harness.resolve/1` (T8.5,
  ADR-0016). Pure apart from reading/writing `Application.get_env(:kazi, :harness)`
  — hence `async: false` with the original env value restored in `on_exit`.

  Each precedence rung is covered independently, plus the opt keep/drop rules and
  the unknown-harness error (atom AND string, without crashing).
  """
  use ExUnit.Case, async: false

  alias Kazi.Harness.CliAdapter
  alias Kazi.Harness.Profile

  setup do
    original = Application.get_env(:kazi, :harness)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:kazi, :harness)
        value -> Application.put_env(:kazi, :harness, value)
      end
    end)

    # Start each test with no app-config harness set; rungs are opted in per test.
    Application.delete_env(:kazi, :harness)
    :ok
  end

  describe "resolve/1 precedence" do
    test "explicit :harness opt beats app config" do
      Application.put_env(:kazi, :harness, :opencode)

      assert {:ok, {CliAdapter, adapter_opts}} = Kazi.Harness.resolve(harness: :claude)
      assert %Profile{id: :claude} = adapter_opts[:profile]
    end

    test "explicit :harness opt beats :goal_harness" do
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(harness: :claude, goal_harness: :opencode)

      assert %Profile{id: :claude} = adapter_opts[:profile]
    end

    test ":goal_harness is used when no explicit :harness opt" do
      # Resolving to the :opencode profile (not the :claude default) proves the
      # goal_harness rung was the id selected.
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(goal_harness: :opencode)

      assert %Profile{id: :opencode} = adapter_opts[:profile]
    end

    test "app config is used when neither :harness nor :goal_harness present" do
      Application.put_env(:kazi, :harness, :opencode)

      assert {:ok, {CliAdapter, adapter_opts}} = Kazi.Harness.resolve([])
      assert %Profile{id: :opencode} = adapter_opts[:profile]
    end

    test "defaults to :claude when nothing is set" do
      assert {:ok, {CliAdapter, adapter_opts}} = Kazi.Harness.resolve([])
      assert %Profile{id: :claude} = adapter_opts[:profile]
    end
  end

  describe "resolve/1 adapter_opts" do
    test "carries the resolved :profile matching the id" do
      assert {:ok, {CliAdapter, adapter_opts}} = Kazi.Harness.resolve(harness: :claude)
      assert %Profile{id: :claude} = adapter_opts[:profile]
    end

    test "carries :model when given" do
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(harness: :claude, model: "claude-opus-4")

      assert adapter_opts[:model] == "claude-opus-4"
    end

    test "omits :model when not given" do
      assert {:ok, {CliAdapter, adapter_opts}} = Kazi.Harness.resolve(harness: :claude)
      refute Keyword.has_key?(adapter_opts, :model)
    end

    test "a top-level :model overrides a :model carried in :adapter_opts" do
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(
                 harness: :claude,
                 model: "override",
                 adapter_opts: [model: "stale"]
               )

      assert adapter_opts[:model] == "override"
    end

    test "keeps supported opts, drops unsupported ones" do
      # :permission_mode IS in the :claude profile's supported_opts; :bogus is not.
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(
                 harness: :claude,
                 adapter_opts: [permission_mode: :acceptEdits, bogus: "drop-me"]
               )

      assert adapter_opts[:permission_mode] == :acceptEdits
      refute Keyword.has_key?(adapter_opts, :bogus)
    end

    test "always keeps :command even if not a harness flag" do
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(
                 harness: :claude,
                 adapter_opts: [command: "/path/to/stub"]
               )

      assert adapter_opts[:command] == "/path/to/stub"
    end

    test "always keeps :env (provider/endpoint vars) even if not a harness flag" do
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(
                 harness: :opencode,
                 adapter_opts: [env: [{"OPENCODE_PROVIDER", "local"}]]
               )

      assert adapter_opts[:env] == [{"OPENCODE_PROVIDER", "local"}]
    end

    test "opencode carries :model and declared :env through to adapter_opts (T8.8, local)" do
      # The local-provider path: --harness opencode --model <provider/model> plus
      # forwarded env points opencode at a locally-hosted model.
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(
                 harness: :opencode,
                 model: "local/qwen3.6",
                 adapter_opts: [env: [{"FOO", "bar"}]]
               )

      assert %Profile{id: :opencode} = adapter_opts[:profile]
      assert adapter_opts[:model] == "local/qwen3.6"
      assert adapter_opts[:env] == [{"FOO", "bar"}]
    end
  end

  describe "resolve/1 goal-file harness precedence (T8.6/T8.7 interaction)" do
    # These mirror exactly the shape Kazi.Runtime.resolve_harness/2 builds from a
    # loaded goal-file `[harness]` table: it passes goal_harness: gh.id and folds
    # the goal-file model in as a fallback under any explicit --model. We assert the
    # precedence at the resolve/1 seam those calls land on — the combination, not
    # the individual rungs already covered above.

    test "goal-file [harness] selects the harness when no explicit --harness" do
      # `goal_harness: :opencode` (from the goal-file) wins over the :claude default
      # and carries the goal-file model through.
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(goal_harness: :opencode, model: "local/qwen3.6")

      assert %Profile{id: :opencode} = adapter_opts[:profile]
      assert adapter_opts[:model] == "local/qwen3.6"
    end

    test "explicit --harness overrides the goal-file [harness] id" do
      # The operator's --harness claude beats a goal-file that declared opencode.
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(harness: :claude, goal_harness: :opencode)

      assert %Profile{id: :claude} = adapter_opts[:profile]
    end

    test "explicit --model overrides the goal-file model (Runtime folds it as fallback)" do
      # Runtime.resolve_harness passes `model: opts[:model] || gh.model`; the
      # resolved :model is therefore the explicit one when present.
      assert {:ok, {CliAdapter, adapter_opts}} =
               Kazi.Harness.resolve(goal_harness: :opencode, model: "operator/override")

      assert adapter_opts[:model] == "operator/override"
    end
  end

  describe "resolve/1 unknown harness" do
    test "an unknown atom id returns {:error, {:unknown_harness, id}}" do
      assert {:error, {:unknown_harness, :nope}} = Kazi.Harness.resolve(harness: :nope)
    end

    test "an unknown string id returns the error without crashing" do
      assert {:error, {:unknown_harness, "nope"}} = Kazi.Harness.resolve(harness: "nope")
    end

    test "a known string id resolves to the matching atom profile" do
      assert {:ok, {CliAdapter, adapter_opts}} = Kazi.Harness.resolve(harness: "claude")
      assert %Profile{id: :claude} = adapter_opts[:profile]
    end

    # T14.3 (ADR-0022): `kazi run --harness antigravity` threads the string
    # "antigravity" into resolve/1; it must map to the :antigravity profile
    # (prompt_via: :file, the #76 non-TTY workaround) — proving the CLI flag
    # resolves the new harness.
    test "the :antigravity string resolves to the antigravity profile (--harness antigravity)" do
      assert {:ok, {CliAdapter, adapter_opts}} = Kazi.Harness.resolve(harness: "antigravity")
      assert %Profile{id: :antigravity, prompt_via: :file} = adapter_opts[:profile]
    end
  end

  describe "resolve/1 all five built-in harnesses (T14.5, ADR-0022)" do
    # The CLI's `kazi run --harness <id>` threads the string id into resolve/1
    # (via Runtime), so every built-in harness id MUST resolve to its profile from
    # both an atom and the string the CLI passes. This pins the CLI<->registry
    # wireup for all five harnesses — claude, opencode, codex, antigravity, claw —
    # so a new profile is not registered in `ids/0` but unreachable from `--harness`.
    for id <- [:claude, :opencode, :codex, :antigravity, :claw] do
      @harness_id id

      test "--harness #{id} resolves to the #{id} profile (atom and string)" do
        assert {:ok, {CliAdapter, atom_opts}} = Kazi.Harness.resolve(harness: @harness_id)
        assert %Profile{id: @harness_id} = atom_opts[:profile]

        assert {:ok, {CliAdapter, string_opts}} =
                 Kazi.Harness.resolve(harness: Atom.to_string(@harness_id))

        assert %Profile{id: @harness_id} = string_opts[:profile]
      end
    end

    test "Registry.ids/0 lists exactly the five built-in harnesses" do
      assert Kazi.Harness.Registry.ids() == [:claude, :opencode, :codex, :antigravity, :claw]
    end

    test "each id in Registry.ids/0 fetches a profile (no orphan id)" do
      for id <- Kazi.Harness.Registry.ids() do
        assert {:ok, %Profile{id: ^id}} = Kazi.Harness.Registry.fetch(id)
      end
    end
  end
end
