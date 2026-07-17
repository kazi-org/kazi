defmodule Kazi.CLIInstallHooksTest do
  @moduledoc """
  T55.2 (UC-068, ADR-0071): the `kazi install-hooks` CLI command -- OPT-IN,
  consent-first, the delivery sibling of `install-skill`.

  Tier 1 pins the argv boundary: `install-hooks` parses to its command tuple,
  carrying `--dir` / `--local` / `--uninstall`.

  Tier 2 drives the real exec core (`Kazi.CLI.run/2`) through
  `ExUnit.CaptureIO` against an INJECTED tmp dir (`--dir` / the `:hooks_dir`
  seam): install reports the path and exits 0; re-install is a no-op;
  `--uninstall` restores the pre-install bytes; a malformed settings file
  exits 1 with one clear line and writes nothing -- and a normal `kazi` run
  (help, version) NEVER writes harness config (consent-first).

  HERMETIC: every write targets a tmp dir; the real `~/.claude` is never
  touched.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-cli-hooks-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, path: Path.join(dir, "settings.json")}
  end

  # ===========================================================================
  # Tier 1 — argv boundary
  # ===========================================================================

  describe "parse/1 — install-hooks" do
    test "`install-hooks` parses with default opts" do
      assert {:install_hooks, opts} = Kazi.CLI.parse(["install-hooks"])
      assert opts[:dir] == nil
      assert opts[:project] == false
      assert opts[:uninstall] == false
    end

    test "`install-hooks --dir <path> --local --uninstall` carries all flags" do
      assert {:install_hooks, opts} =
               Kazi.CLI.parse(["install-hooks", "--dir", "/tmp/x", "--local", "--uninstall"])

      assert opts[:dir] == "/tmp/x"
      assert opts[:project] == true
      assert opts[:uninstall] == true
    end

    test "rejects extra positionals" do
      assert {:error, message} = Kazi.CLI.parse(["install-hooks", "extra"])
      assert message =~ "unexpected argument"
    end
  end

  # ===========================================================================
  # Tier 2 — run/2 exec against a tmp dir
  # ===========================================================================

  describe "run/2 — install-hooks" do
    test "installs into the --dir tmp dir and exits 0", %{dir: dir, path: path} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["install-hooks", "--dir", dir]) == 0
        end)

      assert out =~ "WROTE"
      assert out =~ path
      assert out =~ "kazi bus hook"

      decoded = path |> File.read!() |> Jason.decode!()
      events = decoded["hooks"] |> Map.keys() |> Enum.sort()
      assert events == ["SessionStart", "UserPromptSubmit"]
    end

    test "re-running is a no-op (idempotent)", %{dir: dir, path: path} do
      capture_io(fn -> assert Kazi.CLI.run(["install-hooks", "--dir", dir]) == 0 end)
      first = File.read!(path)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["install-hooks", "--dir", dir]) == 0
        end)

      assert out =~ "UNCHANGED"
      assert File.read!(path) == first
    end

    test "--uninstall restores an operator file's pre-install bytes exactly", %{
      dir: dir,
      path: path
    } do
      original = ~s({\n  "model": "opus",\n  "permissions": { "allow": [] }\n}\n)
      File.mkdir_p!(dir)
      File.write!(path, original)

      capture_io(fn -> assert Kazi.CLI.run(["install-hooks", "--dir", dir]) == 0 end)
      refute File.read!(path) == original

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["install-hooks", "--dir", dir, "--uninstall"]) == 0
        end)

      assert out =~ "REMOVED"
      assert File.read!(path) == original
    end

    test "--uninstall with nothing installed is a no-op exit 0", %{dir: dir} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["install-hooks", "--dir", dir, "--uninstall"]) == 0
        end)

      assert out =~ "UNCHANGED"
    end

    test "a malformed settings file exits 1 with one clear line and writes nothing", %{
      dir: dir,
      path: path
    } do
      File.mkdir_p!(dir)
      File.write!(path, "{ not json")

      {out, err} =
        with_io(:stderr, fn ->
          capture_io(fn ->
            assert Kazi.CLI.run(["install-hooks", "--dir", dir]) == 1
          end)
        end)

      assert out == ""
      assert err =~ "not valid JSON"
      assert err =~ "nothing was written"
      # ONE clear line on stderr.
      assert err |> String.trim() |> String.split("\n") |> length() == 1
      assert File.read!(path) == "{ not json"
    end

    test "--local targets settings.local.json (the LOCAL, uncommitted file)", %{dir: dir} do
      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["install-hooks", "--dir", dir, "--local"]) == 0
        end)

      local = Path.join(dir, "settings.local.json")
      assert out =~ local
      assert File.exists?(local)
      # NEVER the committed project settings file (ADR-0071 d3 / ADR-0034).
      refute File.exists?(Path.join(dir, "settings.json"))
    end

    test "honors the :hooks_dir inject seam (no flag)", %{dir: dir, path: path} do
      capture_io(fn ->
        assert Kazi.CLI.run(["install-hooks"], hooks_dir: dir) == 0
      end)

      assert File.exists?(path)
    end
  end

  # ===========================================================================
  # consent-first: a NORMAL run never writes harness config
  # ===========================================================================

  describe "consent-first (opt-in, ADR-0071 d1)" do
    test "neither help nor version writes settings to the injected dir", %{dir: dir} do
      capture_io(fn ->
        assert Kazi.CLI.run(["help"], hooks_dir: dir) == 0
        assert Kazi.CLI.run(["--version"], hooks_dir: dir) == 0
        assert Kazi.CLI.run(["help", "--json"], hooks_dir: dir) == 0
      end)

      refute File.exists?(Path.join(dir, "settings.json"))
      refute File.dir?(dir)
    end
  end

  # ===========================================================================
  # help --json lists install-hooks (the command table includes it)
  # ===========================================================================

  test "help --json lists install-hooks with its flags" do
    out = capture_io(fn -> Kazi.CLI.run(["help", "--json"]) end)
    {:ok, payload} = Jason.decode(String.trim(out))

    cmd = Enum.find(payload["commands"], &(&1["name"] == "install-hooks"))
    assert cmd, "help --json does not list install-hooks"
    assert cmd["summary"] != ""

    flag_names = Enum.map(cmd["flags"], & &1["name"])
    assert "--dir" in flag_names
    assert "--local" in flag_names
    assert "--uninstall" in flag_names
  end
end
