defmodule Kazi.CLILintTest do
  @moduledoc """
  T12.7 (ADR-0020 §Decision 3): the `kazi lint <goal-file>` command — the
  advisory SECOND net fuzzy-warning on near-duplicate group NAMES.

  Tier 1 pins the argv boundary: `lint` parses into the right command tuple,
  carrying `--json`, requiring the `<goal-file>` positional.

  Tier 2 drives the REAL CLI exec core (`Kazi.CLI.run/2`) through
  `ExUnit.CaptureIO`: it lints goal-files written to a tmp dir (under
  `System.tmp_dir!`, cleaned up `on_exit`) and asserts the human + `--json`
  surfaces. The KEY property: lint is ADVISORY — it exits 0 even WHEN it emits
  warnings (a name near-duplicate is a smell, not a load failure); only a genuine
  load failure is a non-zero exit. No read-model / network / harness — lint is a
  pure load + compare.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-cli-lint-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # A goal-file with two groups whose ids differ (so the loader's id-uniqueness
  # guard accepts both) but whose display NAMES are near-duplicates — the gap the
  # second net exists for.
  defp near_duplicate_goal_file(dir) do
    path = Path.join(dir, "near_dup.toml")

    File.write!(path, """
    id = "near-dup-names"

    [[group]]
    id = "identity-access"
    name = "Identity & Access"

    [[group]]
    id = "idaccess"
    name = "Identity and Access"

    [[predicate]]
    id = "p1"
    provider = "test_runner"
    group = "identity-access"
    """)

    path
  end

  # A goal-file whose group names are clearly distinct — lint must stay silent.
  defp distinct_goal_file(dir) do
    path = Path.join(dir, "distinct.toml")

    File.write!(path, """
    id = "distinct-names"

    [[group]]
    id = "identity"
    name = "Identity"

    [[group]]
    id = "billing"
    name = "Billing"

    [[predicate]]
    id = "p1"
    provider = "test_runner"
    group = "identity"
    """)

    path
  end

  # ===========================================================================
  # Tier 1 — argv parsing
  # ===========================================================================

  describe "parse/1 — lint" do
    test "parses `lint <goal-file>`, defaulting json to false" do
      assert {:lint, "g.toml", opts} = Kazi.CLI.parse(["lint", "g.toml"])
      assert opts[:json] == false
    end

    test "carries the --json flag" do
      assert {:lint, "g.toml", opts} = Kazi.CLI.parse(["lint", "g.toml", "--json"])
      assert opts[:json] == true
    end

    test "requires the <goal-file> positional" do
      assert {:error, message} = Kazi.CLI.parse(["lint"])
      assert message =~ "requires a <goal-file>"
    end

    test "rejects extra positionals" do
      assert {:error, message} = Kazi.CLI.parse(["lint", "g.toml", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — near-duplicate NAMES warn, but lint stays ADVISORY (exit 0)
  # ===========================================================================

  describe "run/2 — near-duplicate group names warn (advisory, exit 0)" do
    test "names BOTH groups in the warning and exits 0 (human surface)", %{dir: dir} do
      goal_file = near_duplicate_goal_file(dir)

      out =
        capture_io(fn ->
          # ADVISORY: exit 0 even though a warning is emitted.
          assert Kazi.CLI.run(["lint", goal_file]) == 0
        end)

      assert out =~ "LINT"
      assert out =~ "warning:"
      # Names BOTH near-duplicate groups (the verbatim display labels).
      assert out =~ "Identity & Access"
      assert out =~ "Identity and Access"
      assert out =~ "ADVISORY"
    end

    test "--json emits the warning list and still exits 0", %{dir: dir} do
      goal_file = near_duplicate_goal_file(dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["lint", goal_file, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["goal_id"] == "near-dup-names"
      assert payload["count"] == 1

      assert [warning] = payload["warnings"]
      assert warning["names"] == ["Identity & Access", "Identity and Access"]
      assert warning["group_ids"] == ["identity-access", "idaccess"]
      assert is_number(warning["similarity"])

      # JSON-only: no human prose interleaved on stdout.
      refute out =~ "LINT"
    end
  end

  # ===========================================================================
  # Tier 2 — clearly-distinct names emit NO warning
  # ===========================================================================

  describe "run/2 — distinct names are silent (exit 0)" do
    test "human surface reports a clean lint", %{dir: dir} do
      goal_file = distinct_goal_file(dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["lint", goal_file]) == 0
        end)

      assert out =~ "no near-duplicate group names"
      refute out =~ "warning:"
    end

    test "--json reports an empty warning list (count 0)", %{dir: dir} do
      goal_file = distinct_goal_file(dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["lint", goal_file, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["count"] == 0
      assert payload["warnings"] == []
    end

    test "the shipped grouped example lints clean", %{dir: _dir} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["lint", "priv/examples/grouped_taxonomy.toml"]) == 0
        end)

      assert out =~ "no near-duplicate group names"
    end
  end

  # ===========================================================================
  # Tier 2 — a genuine load FAILURE is a real error (non-zero), unlike a warning
  # ===========================================================================

  describe "run/2 — lint load errors (the only non-zero exit)" do
    test "a missing goal-file is a clean load error on stderr (exit 1)" do
      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["lint", "no-such-goal.toml"]) == 1
        end)

      assert out =~ "could not load goal-file"
    end

    test "a missing goal-file under --json is a JSON error envelope (exit 1)" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["lint", "no-such-goal.toml", "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "could not load goal-file"
    end
  end
end
