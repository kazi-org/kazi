defmodule Kazi.CLI.HelpParityTest do
  @moduledoc """
  Registry <-> human-usage parity for `kazi help`.

  `Kazi.CLIHelpSchemaTest` pins the MACHINE surface (`help --json`, generated from
  `Kazi.CLI`'s `@commands`) against the parser, and `Kazi.TeachCoherenceTest` pins
  the SKILL/AGENTS docs against that same surface. The remaining gap this guard
  closes is the HUMAN surface: `kazi help` (no `--json`) prints the hand-written
  `@usage` prose, which can silently fall out of sync with the registered command
  table.

  That drift is exactly how `dashboard` (ADR-0057) and `spec` (ADR-0050) shipped
  registered in `help --json` yet absent from the human `kazi help` a user reads
  first. This test makes the two surfaces load-bearing on each other: EVERY
  registered command must appear as a `kazi <command>` token in the human usage
  text, so a new command cannot be added to the table without also teaching the
  human help about it (ADR-0034, docs land with the code).

  HERMETIC: both surfaces are pure in-process reads (`Kazi.CLI.run/1`), no binary,
  no read-model, no network.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # The registered command names, read from the authoritative generated surface
  # (`help --json`, itself generated from `Kazi.CLI`'s `@commands`).
  defp registered_commands do
    out = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end)
    {:ok, payload} = Jason.decode(String.trim(out))
    payload["commands"] |> Enum.map(& &1["name"]) |> MapSet.new()
  end

  # The human usage prose `kazi help` prints (the default, no --json).
  defp human_usage do
    capture_io(fn -> assert Kazi.CLI.run(["help"]) == 0 end)
  end

  # A command is "listed" in the human usage when it appears as a `kazi <command>`
  # invocation token (a word boundary after the name so `bus` does not match
  # `business`, `plan` does not match `planning`).
  defp usage_lists?(usage, command), do: usage =~ ~r/\bkazi #{Regex.escape(command)}\b/

  test "every registered command is listed in the human `kazi help` usage" do
    usage = human_usage()

    missing =
      registered_commands()
      |> Enum.reject(&usage_lists?(usage, &1))
      |> Enum.sort()

    assert missing == [],
           "these registered commands are missing from the human `kazi help` usage " <>
             "(add a `kazi <command>` line to @usage): #{inspect(missing)}"
  end

  test "dashboard and spec are listed in the human usage (the drift these guard, ADR-0057/ADR-0050)" do
    usage = human_usage()

    assert usage_lists?(usage, "dashboard")
    assert usage_lists?(usage, "spec")
  end
end
