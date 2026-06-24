defmodule Kazi.CLIExportTest do
  @moduledoc """
  T12.6 (ADR-0020 §Decision 5): the `kazi export <goal-file> --obsidian <dir>`
  CLI command resolves a goal-file and writes an Obsidian vault.

  Tier 1 pins the argv boundary: `export` parses into the right command tuple,
  carrying `--obsidian` and `--json`.

  Tier 2 drives the REAL CLI exec core (`Kazi.CLI.run/2`) through
  `ExUnit.CaptureIO`: it loads the shipped grouped example goal-file and writes
  the vault to a tmp dir (under `System.tmp_dir!`, cleaned up `on_exit`), asserts
  the notes/Mermaid/OVERVIEW are present, and exercises both the human and the
  `--json` summary surfaces plus the error paths (missing --obsidian, bad
  goal-file). No read-model / network / harness — export is a pure load + write.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @grouped_example "priv/examples/grouped_taxonomy.toml"

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-cli-export-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # ===========================================================================
  # Tier 1 — argv parsing
  # ===========================================================================

  describe "parse/1 — export" do
    test "parses `export <goal-file> --obsidian <dir>`" do
      assert {:export, "g.toml", opts} =
               Kazi.CLI.parse(["export", "g.toml", "--obsidian", "/tmp/vault"])

      assert opts[:obsidian] == "/tmp/vault"
      assert opts[:json] == false
    end

    test "carries the --json flag" do
      assert {:export, "g.toml", opts} =
               Kazi.CLI.parse(["export", "g.toml", "--obsidian", "/tmp/vault", "--json"])

      assert opts[:json] == true
    end

    test "requires the <goal-file> positional" do
      assert {:error, message} = Kazi.CLI.parse(["export", "--obsidian", "/tmp/vault"])
      assert message =~ "requires a <goal-file>"
    end

    test "rejects extra positionals" do
      assert {:error, message} = Kazi.CLI.parse(["export", "g.toml", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — the real export path (load + write the vault)
  # ===========================================================================

  describe "run/2 — export the shipped grouped example" do
    test "writes the vault and reports it (human surface)", %{dir: dir} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["export", @grouped_example, "--obsidian", dir]) == 0
        end)

      assert out =~ "EXPORTED"
      assert out =~ "vault=#{dir}"

      # The vault is on disk: OVERVIEW + a note per group/predicate.
      assert File.exists?(Path.join(dir, "OVERVIEW.md"))
      assert File.exists?(Path.join(dir, "identity-access.md"))
      assert File.exists?(Path.join(dir, "billing.md"))
      assert File.exists?(Path.join(dir, "predicate-placeholder.md"))

      overview = File.read!(Path.join(dir, "OVERVIEW.md"))
      assert overview =~ "```mermaid"
      assert overview =~ "## Per-group rollup"
    end

    test "links parent↔child via [[wikilinks]] and tags by verdict", %{dir: dir} do
      capture_io(fn ->
        assert Kazi.CLI.run(["export", @grouped_example, "--obsidian", dir]) == 0
      end)

      # identity-access is the pillar; sign-up is its child domain.
      assert File.read!(Path.join(dir, "identity-access.md")) =~ "[[sign-up]]"
      assert File.read!(Path.join(dir, "sign-up.md")) =~ "[[identity-access]]"
      # Without a live run, the placeholder predicate is pending.
      assert File.read!(Path.join(dir, "predicate-placeholder.md")) =~ "#pending"
    end

    test "--json emits a single JSON summary of what was written", %{dir: dir} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["export", @grouped_example, "--obsidian", dir, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["format"] == "obsidian"
      assert payload["goal_id"] == "grouped-taxonomy-example"
      assert payload["vault"] == dir
      assert payload["counts"]["groups"] == 3
      assert is_list(payload["notes"])
      # JSON-only: no human prose interleaved.
      refute out =~ "EXPORTED"
    end
  end

  describe "run/2 — export error paths" do
    test "missing --obsidian is a clean usage error (exit 1)" do
      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["export", @grouped_example]) == 1
        end)

      assert out =~ "requires --obsidian"
    end

    test "missing --obsidian under --json is a JSON error envelope (exit 1)" do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["export", @grouped_example, "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "requires --obsidian"
    end

    test "a bad goal-file is a clean load error (exit 1)", %{dir: dir} do
      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["export", "no-such-goal.toml", "--obsidian", dir]) == 1
        end)

      assert out =~ "could not load goal-file"
    end
  end
end
