defmodule Kazi.Teach.InstallHooksTest do
  @moduledoc """
  T55.2 (UC-068, ADR-0071 decisions 1/2/3/6): `Kazi.Teach.InstallHooks` -- the
  opt-in session-bus delivery installer, pinned against the R-E55-1 risk
  (clobbering or corrupting an operator's own harness settings).

  Acceptance (the task's own list):

    * install into ABSENT settings creates a valid file;
    * install into settings holding an operator's own unrelated hooks + keys
      preserves every one of them BYTE-IDENTICALLY;
    * install twice is a no-op (idempotent);
    * `--uninstall` restores the pre-install bytes EXACTLY;
    * a malformed existing settings file fails with ONE clear line and writes
      NOTHING.

  HERMETIC: every write targets a tmp dir (`:dir`); the real `~/.claude` is
  never touched.
  """
  use ExUnit.Case, async: true

  alias Kazi.Teach.InstallHooks

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-install-hooks-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, path: Path.join(dir, "settings.json")}
  end

  # An operator's settings file with their OWN hooks and keys, in deliberately
  # non-canonical formatting (odd spacing, 3-space indent) -- byte preservation
  # must survive formatting the installer would never produce itself.
  @operator_settings """
  {
     "model": "opus",
     "hooks": {
        "SessionStart": [
           { "matcher":"",   "hooks": [ {"type":"command","command":"echo operator-start"} ] }
        ],
        "PreToolUse": [
           { "matcher": "Bash", "hooks": [ {"type":"command","command":"./guard.sh"} ] }
        ]
     },
     "permissions": { "allow": [ "Bash(ls:*)" ] }
  }
  """

  describe "install into ABSENT settings" do
    test "creates a valid settings file registering both events", %{dir: dir, path: path} do
      assert {:ok, %{status: :installed, path: ^path}} = InstallHooks.install(dir: dir)

      decoded = path |> File.read!() |> Jason.decode!()

      assert [entry_start] = decoded["hooks"]["SessionStart"]

      assert [%{"type" => "command", "command" => "kazi bus hook session-start"}] =
               entry_start["hooks"]

      assert [entry_turn] = decoded["hooks"]["UserPromptSubmit"]
      assert [%{"type" => "command", "command" => "kazi bus hook turn"}] = entry_turn["hooks"]
    end

    test "binds ONLY SessionStart, UserPromptSubmit, and Notification (ADR-0071 d2/T60.3 -- never Stop)",
         %{
           dir: dir,
           path: path
         } do
      {:ok, _} = InstallHooks.install(dir: dir)
      decoded = path |> File.read!() |> Jason.decode!()

      assert Map.keys(decoded["hooks"]) |> Enum.sort() == [
               "Notification",
               "SessionStart",
               "UserPromptSubmit"
             ]
    end

    test "registers the Notification hook (T60.3, issue #1156)", %{dir: dir, path: path} do
      {:ok, _} = InstallHooks.install(dir: dir)
      decoded = path |> File.read!() |> Jason.decode!()

      assert [entry] = decoded["hooks"]["Notification"]
      assert [%{"type" => "command", "command" => "kazi bus hook notification"}] = entry["hooks"]
    end
  end

  describe "merge, never clobber (R-E55-1)" do
    test "an operator's own hooks and keys survive byte-identically", %{dir: dir, path: path} do
      File.write!(path, @operator_settings)

      assert {:ok, %{status: :installed}} = InstallHooks.install(dir: dir)
      installed = File.read!(path)

      # Every operator-owned byte sequence survives verbatim, including the
      # non-canonical spacing the installer would never emit itself.
      for chunk <- [
            ~s("model": "opus"),
            ~s({ "matcher":"",   "hooks": [ {"type":"command","command":"echo operator-start"} ] }),
            ~s({ "matcher": "Bash", "hooks": [ {"type":"command","command":"./guard.sh"} ] }),
            ~s|"permissions": { "allow": [ "Bash(ls:*)" ] }|
          ] do
        assert String.contains?(installed, chunk),
               "operator-owned bytes were altered: missing #{inspect(chunk)}"
      end

      # And the kazi entries are structurally present alongside them.
      decoded = Jason.decode!(installed)
      start_cmds = for e <- decoded["hooks"]["SessionStart"], h <- e["hooks"], do: h["command"]
      assert "echo operator-start" in start_cmds
      assert "kazi bus hook session-start" in start_cmds

      assert [%{"hooks" => [%{"command" => "kazi bus hook turn"}]}] =
               decoded["hooks"]["UserPromptSubmit"]

      # The operator's other event is untouched.
      assert [%{"matcher" => "Bash"}] = decoded["hooks"]["PreToolUse"]
    end

    test "install twice is a byte-level no-op (idempotent)", %{dir: dir, path: path} do
      File.write!(path, @operator_settings)

      {:ok, %{status: :installed}} = InstallHooks.install(dir: dir)
      first = File.read!(path)

      assert {:ok, %{status: :unchanged}} = InstallHooks.install(dir: dir)
      assert File.read!(path) == first
    end

    test "install twice into a fresh (absent-created) file is a no-op", %{dir: dir, path: path} do
      {:ok, %{status: :installed}} = InstallHooks.install(dir: dir)
      first = File.read!(path)

      assert {:ok, %{status: :unchanged}} = InstallHooks.install(dir: dir)
      assert File.read!(path) == first
    end

    test "a partially-installed file gains only the missing event", %{dir: dir, path: path} do
      # Operator hand-carried the session-start hook already; only turn is missing.
      File.write!(path, """
      {
        "hooks": {
          "SessionStart": [{ "hooks": [{ "type": "command", "command": "kazi bus hook session-start" }] }]
        }
      }
      """)

      {:ok, %{status: :installed}} = InstallHooks.install(dir: dir)
      decoded = path |> File.read!() |> Jason.decode!()

      assert [%{"hooks" => [%{"command" => "kazi bus hook session-start"}]}] =
               decoded["hooks"]["SessionStart"]

      assert [%{"hooks" => [%{"command" => "kazi bus hook turn"}]}] =
               decoded["hooks"]["UserPromptSubmit"]
    end
  end

  describe "uninstall" do
    test "restores the pre-install bytes EXACTLY on an operator file", %{dir: dir, path: path} do
      File.write!(path, @operator_settings)

      {:ok, %{status: :installed}} = InstallHooks.install(dir: dir)
      refute File.read!(path) == @operator_settings

      assert {:ok, %{status: :removed}} = InstallHooks.uninstall(dir: dir)
      assert File.read!(path) == @operator_settings
    end

    test "after an absent-file install, uninstall restores absence", %{dir: dir, path: path} do
      {:ok, %{status: :installed}} = InstallHooks.install(dir: dir)
      assert File.exists?(path)

      assert {:ok, %{status: :removed, deleted: true}} = InstallHooks.uninstall(dir: dir)
      refute File.exists?(path)
    end

    test "restores a `{}` original exactly (never deletes an operator file)", %{
      dir: dir,
      path: path
    } do
      File.write!(path, "{}")

      {:ok, %{status: :installed}} = InstallHooks.install(dir: dir)
      assert {:ok, %{status: :removed}} = InstallHooks.uninstall(dir: dir)
      assert File.read!(path) == "{}"
    end

    test "is a no-op when nothing is installed", %{dir: dir, path: path} do
      File.write!(path, @operator_settings)

      assert {:ok, %{status: :unchanged}} = InstallHooks.uninstall(dir: dir)
      assert File.read!(path) == @operator_settings
    end

    test "is a no-op when the file is absent", %{dir: dir} do
      assert {:ok, %{status: :unchanged}} = InstallHooks.uninstall(dir: dir)
    end

    test "--uninstall removes the Notification hook too, exact-inverse symmetry (T60.3)", %{
      dir: dir,
      path: path
    } do
      File.write!(path, @operator_settings)

      {:ok, %{status: :installed}} = InstallHooks.install(dir: dir)
      installed = File.read!(path)
      assert installed =~ "kazi bus hook notification"

      assert {:ok, %{status: :removed}} = InstallHooks.uninstall(dir: dir)
      assert File.read!(path) == @operator_settings
    end

    test "never removes an entry mixing an operator command with kazi's", %{dir: dir, path: path} do
      mixed = """
      {
        "hooks": {
          "SessionStart": [
            { "hooks": [{ "type": "command", "command": "kazi bus hook session-start" }, { "type": "command", "command": "echo mine" }] }
          ]
        }
      }
      """

      File.write!(path, mixed)
      assert {:ok, %{status: :unchanged}} = InstallHooks.uninstall(dir: dir)
      assert File.read!(path) == mixed
    end
  end

  describe "a malformed settings file" do
    test "fails with one clear line and writes NOTHING", %{dir: dir, path: path} do
      File.write!(path, "{ this is not json")

      assert {:error, message} = InstallHooks.install(dir: dir)
      assert message =~ "not valid JSON"
      assert message =~ "nothing was written"
      refute message =~ "\n"
      assert File.read!(path) == "{ this is not json"
    end

    test "a non-object root fails and writes nothing", %{dir: dir, path: path} do
      File.write!(path, ~s(["an", "array"]))

      assert {:error, message} = InstallHooks.install(dir: dir)
      assert message =~ "not a JSON object"
      assert File.read!(path) == ~s(["an", "array"])
    end

    test "a non-object \"hooks\" value fails and writes nothing", %{dir: dir, path: path} do
      File.write!(path, ~s({"hooks": "nope"}))

      assert {:error, message} = InstallHooks.install(dir: dir)
      assert message =~ "non-object"
      assert File.read!(path) == ~s({"hooks": "nope"})
    end

    test "uninstall on malformed JSON fails and writes nothing", %{dir: dir, path: path} do
      File.write!(path, "{ broken")

      assert {:error, message} = InstallHooks.uninstall(dir: dir)
      assert message =~ "not valid JSON"
      assert File.read!(path) == "{ broken"
    end
  end

  describe "install targets" do
    test "the default path is the user-level settings.json under ~/.claude" do
      assert InstallHooks.settings_path() ==
               Path.join(Path.expand(Path.join("~", ".claude")), "settings.json")
    end

    test ":project targets the LOCAL, uncommitted settings.local.json", %{dir: dir} do
      # NEVER the committed settings.json of a project (ADR-0071 d3 / ADR-0034).
      assert InstallHooks.settings_path(dir: dir, project: true) ==
               Path.join(dir, "settings.local.json")
    end

    test ":project without :dir resolves under <cwd>/.claude" do
      assert InstallHooks.settings_path(project: true) ==
               Path.join([File.cwd!(), ".claude", "settings.local.json"])
    end

    test "install honors :project under :dir", %{dir: dir} do
      {:ok, %{path: path, status: :installed}} = InstallHooks.install(dir: dir, project: true)
      assert Path.basename(path) == "settings.local.json"
      assert path |> File.read!() |> Jason.decode!() |> Map.has_key?("hooks")
    end
  end
end
