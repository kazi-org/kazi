defmodule Kazi.CLIMemoryTest do
  @moduledoc """
  ADR-0062: the `kazi memory recall` CLI — the operator/orchestrator-facing
  surface over `Kazi.Memory.SemanticIndex.recall/3` (decision 3, "surfaced
  three ways, all the same function").

  Tier 1 pins the argv boundary: `recall` parses into the `{:memory, sub,
  args, opts}` tuple carrying `--workspace` / `--budget` / `--json`; a missing
  or unknown subcommand, or a missing query, is a clear usage error.

  Tier 2 drives the real CLI exec core (`Kazi.CLI.run/2`) through
  `ExUnit.CaptureIO` against a real fixture corpus on disk (no network, no
  external process — `SemanticIndex` is pure SQLite FTS5).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.CLI

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
  end

  defp fixture_dir do
    dir = Path.join(System.tmp_dir!(), "kazi-cli-memory-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs"))

    File.write!(Path.join(dir, "docs/lore.md"), """
    # Lore

    ## Landmine: budget overflow
    Recall must never exceed the caller's token budget under any circumstance.
    """)

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp run_capture(argv) do
    code = :erlang.make_ref()
    Process.put(code, nil)
    out = capture_io(fn -> Process.put(code, CLI.run(argv)) end)
    {Process.get(code), out}
  end

  describe "parse/1 — the memory command boundary" do
    test "recall parses into the memory tuple with its query + flags" do
      assert {:memory, "recall", ["budget overflow"], opts} =
               CLI.parse(["memory", "recall", "budget overflow", "--budget", "200", "--json"])

      assert opts[:budget] == 200
      assert opts[:json] == true
    end

    test "a missing subcommand is a usage error naming `recall`" do
      assert {:error, message} = CLI.parse(["memory"])
      assert message =~ "requires a <subcommand>"
      assert message =~ "recall"
    end

    test "an unknown subcommand is a clear error" do
      assert {:error, message} = CLI.parse(["memory", "bogus"])
      assert message =~ "unknown memory subcommand"
    end

    test "a missing query is a clear error (never a prompt)" do
      assert {:error, message} = CLI.parse(["apply"])
      assert message =~ "goal-file"
    end
  end

  describe "run/2 — memory recall end to end" do
    test "recalls a matching chunk with its path:line attribution (human output)" do
      dir = fixture_dir()

      {code, out} =
        run_capture([
          "memory",
          "recall",
          "budget overflow",
          "--budget",
          "200",
          "--workspace",
          dir
        ])

      assert code == 0
      assert out =~ "docs/lore.md:3"
      assert out =~ "never exceed"
    end

    test "--json emits a single parseable object, no human prose interleaved" do
      dir = fixture_dir()

      {code, out} =
        run_capture([
          "memory",
          "recall",
          "budget overflow",
          "--budget",
          "200",
          "--workspace",
          dir,
          "--json"
        ])

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["command"] == "memory"
      assert payload["subcommand"] == "recall"
      assert payload["query"] == "budget overflow"
      assert [snippet] = payload["snippets"]
      assert snippet["path"] == "docs/lore.md"
      assert snippet["line"] == 3
      refute out =~ "recall "
    end

    test "an empty-corpus query is a JSON error + non-zero exit under --json, never a prompt" do
      {code, out} = run_capture(["memory", "recall", "--json"])

      assert code != 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "requires a <query>"
    end
  end
end
