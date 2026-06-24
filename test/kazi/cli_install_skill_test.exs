defmodule Kazi.CLIInstallSkillTest do
  @moduledoc """
  T16.2 (UC-031, ADR-0024 decision 1): the `kazi install-skill` CLI command —
  OPT-IN, consent-first.

  Tier 1 pins the argv boundary: `install-skill` parses to its command tuple,
  carrying the optional `--dir`.

  Tier 2 drives the real exec core (`Kazi.CLI.run/2`) through `ExUnit.CaptureIO`:
  it writes the SKILL.md to an INJECTED tmp dir (`--dir` / the `:skill_dir`
  inject seam), reports the path, and exits 0 — and a normal `kazi` run (help,
  version, an unrelated command) NEVER writes the skill (consent-first).

  HERMETIC: every write targets a tmp dir; the real `~/.claude` is never touched.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-cli-skill-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # ===========================================================================
  # Tier 1 — argv boundary
  # ===========================================================================

  describe "parse/1 — install-skill" do
    test "`install-skill` parses to its command with a nil dir by default" do
      assert {:install_skill, opts} = Kazi.CLI.parse(["install-skill"])
      assert opts[:dir] == nil
    end

    test "`install-skill --dir <path>` carries the injected dir" do
      assert {:install_skill, opts} = Kazi.CLI.parse(["install-skill", "--dir", "/tmp/x"])
      assert opts[:dir] == "/tmp/x"
    end

    test "rejects extra positionals" do
      assert {:error, message} = Kazi.CLI.parse(["install-skill", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — run/2 exec (writes to a tmp dir, exits 0)
  # ===========================================================================

  describe "run/2 — install-skill" do
    test "writes SKILL.md to the --dir tmp dir and exits 0", %{dir: dir} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["install-skill", "--dir", dir]) == 0
        end)

      path = Path.join(dir, "SKILL.md")
      assert File.exists?(path)
      assert out =~ "WROTE"
      assert out =~ path
      # It teaches the recipe in the report.
      assert out =~ "next_action"
    end

    test "honors the :skill_dir inject seam (no flag)", %{dir: dir} do
      capture_io(fn ->
        assert Kazi.CLI.run(["install-skill"], skill_dir: dir) == 0
      end)

      assert File.exists?(Path.join(dir, "SKILL.md"))
    end

    test "the written skill references the primary verbs (plan/approve/apply)", %{dir: dir} do
      capture_io(fn -> Kazi.CLI.run(["install-skill", "--dir", dir]) end)
      content = File.read!(Path.join(dir, "SKILL.md"))

      assert content =~ "kazi plan --json"
      assert content =~ "kazi approve"
      assert content =~ "kazi apply"
      assert content =~ "--harness"
    end
  end

  # ===========================================================================
  # consent-first: a NORMAL run never writes the skill
  # ===========================================================================

  describe "consent-first (opt-in)" do
    test "neither help nor version writes a skill to the injected dir", %{dir: dir} do
      # Point the inject seam at the tmp dir, then run UNRELATED commands. None of
      # them is `install-skill`, so none may write — only the explicit command does.
      capture_io(fn ->
        assert Kazi.CLI.run(["help"], skill_dir: dir) == 0
        assert Kazi.CLI.run(["--version"], skill_dir: dir) == 0
        assert Kazi.CLI.run(["help", "--json"], skill_dir: dir) == 0
      end)

      refute File.exists?(Path.join(dir, "SKILL.md"))
      refute File.dir?(dir)
    end
  end

  # ===========================================================================
  # help --json lists install-skill (the command table includes it)
  # ===========================================================================

  test "help --json lists install-skill with its --dir flag" do
    out = capture_io(fn -> Kazi.CLI.run(["help", "--json"]) end)
    {:ok, payload} = Jason.decode(String.trim(out))

    cmd = Enum.find(payload["commands"], &(&1["name"] == "install-skill"))
    assert cmd, "help --json does not list install-skill"
    assert cmd["summary"] != ""

    flag_names = Enum.map(cmd["flags"], & &1["name"])
    assert "--dir" in flag_names
  end
end
