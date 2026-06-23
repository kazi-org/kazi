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
  end
end
