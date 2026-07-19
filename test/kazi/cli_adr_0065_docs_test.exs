defmodule Kazi.CLIAdr0065DocsTest do
  @moduledoc """
  T50.6 (ADR-0065, ADR-0034 docs-land-with-code): the WHOLE ADR-0065 flag
  surface — worktree-by-default's `--in-place` opt-out (T50.1), the
  supervised-checkpoint pair `--pause-between-waves`/`--resume` (T50.3), and
  the fleet pair `--fleet`/`--fleet-concurrency` (T50.4/T50.5) — is
  self-describing at runtime: every flag appears in the HUMAN help text AND in
  `kazi help --json`'s `apply` entry (generated from `@commands`/`@switches`/
  `@flag_docs`, the same tables the parser reads), each with a non-empty
  description. The argv tier pins that the checkpoint flags actually PARSE
  (they shipped as scheduler seams in T50.3; the CLI surface is T50.6's).

  Pure string/JSON assertions on in-process data — no binary build, no
  network, no read-model (mirrors `Kazi.CLIHelpSchemaTest`).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # The ADR-0065 apply flags, as the literal `--flag` strings both help
  # surfaces render.
  @adr_0065_flags [
    "--in-place",
    "--pause-between-waves",
    "--resume",
    "--fleet",
    "--fleet-concurrency"
  ]

  describe "human help (`kazi help`)" do
    test "names every ADR-0065 flag" do
      out = capture_io(fn -> assert Kazi.CLI.run(["help"]) == 0 end)

      for flag <- @adr_0065_flags do
        assert out =~ flag,
               "human help text does not mention #{flag} (ADR-0065 surface, T50.6)"
      end
    end
  end

  describe "`kazi help --json` apply flags" do
    test "lists every ADR-0065 flag with a non-empty description" do
      out = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end)
      assert {:ok, payload} = Jason.decode(String.trim(out))

      apply_flags =
        payload["commands"]
        |> Enum.find(&(&1["name"] == "apply"))
        |> Map.fetch!("flags")

      by_name = Map.new(apply_flags, &{&1["name"], &1})

      for flag <- @adr_0065_flags do
        entry = by_name[flag]

        assert entry != nil,
               "`help --json`'s apply entry lists no #{flag} — is it in the " <>
                 "@commands apply flags allow-list?"

        assert is_binary(entry["description"]) and entry["description"] != "",
               "#{flag} has no @flag_docs description"
      end
    end
  end

  describe "argv boundary — the T50.3 checkpoint flags parse" do
    test "`--parallel --pause-between-waves` carries the pause flag" do
      assert {:run, "g.toml", opts} =
               Kazi.CLI.parse(["apply", "g.toml", "--parallel", "--pause-between-waves"])

      assert opts[:parallel] == true
      assert opts[:pause_between_waves] == true
    end

    test "`--resume <token>` carries the token" do
      assert {:run, "g.toml", opts} =
               Kazi.CLI.parse(["apply", "g.toml", "--parallel", "--resume", "pause-abc123"])

      assert opts[:resume] == "pause-abc123"
    end

    test "absent, both default off (unchanged behavior)" do
      assert {:run, "g.toml", opts} = Kazi.CLI.parse(["apply", "g.toml"])

      assert opts[:pause_between_waves] == false
      assert opts[:resume] == nil
    end
  end
end
