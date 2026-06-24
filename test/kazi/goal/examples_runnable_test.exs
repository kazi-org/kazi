defmodule Kazi.Goal.ExamplesRunnableTest do
  @moduledoc """
  T18.1 regression guard: every shipped example goal-file under `priv/examples/`
  must load, and every `test_runner` (`:tests`) predicate must express its command
  as a single executable `cmd` plus a list `args` -- NOT a whole command line in
  `cmd`.

  The bug this guards against: `cmd = "go test ./..."` is handed verbatim to
  `System.cmd/3` as the executable name, which fails with
  `{:cmd_unrunnable, :enoent}` (there is no binary literally named "go test ./...").
  The fix is `cmd = "go"`, `args = ["test", "./..."]`. See docs/lore.md L-0012.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Predicate

  @examples_dir Path.join([File.cwd!(), "priv", "examples"])

  # Every *.toml / *.goal.toml under priv/examples is a shipped example users copy.
  defp example_files do
    Path.wildcard(Path.join(@examples_dir, "*.toml"))
  end

  test "there is at least one shipped example to check" do
    assert example_files() != [], "expected example goal-files under priv/examples/"
  end

  for path <- Path.wildcard(Path.join([File.cwd!(), "priv", "examples", "*.toml"])) do
    @path path

    test "#{Path.basename(path)} loads and every test_runner cmd is a single executable" do
      assert {:ok, %Goal{predicates: predicates}} = Loader.load(@path)

      for %Predicate{kind: :tests, id: id, config: config} <- predicates do
        cmd = config[:cmd]

        assert is_binary(cmd) and cmd != "",
               "#{Path.basename(@path)} predicate #{inspect(id)}: :tests cmd must be a non-empty string"

        # The load-bearing guard: cmd is ONE executable token, not a command line.
        # `String.split/1` on whitespace yields >1 element exactly when someone
        # wrote `cmd = "go test ./..."` instead of cmd + args (the L-0012 bug).
        refute String.contains?(cmd, " "),
               "#{Path.basename(@path)} predicate #{inspect(id)}: cmd #{inspect(cmd)} " <>
                 "contains whitespace -- it is parsed as ONE executable by System.cmd/3 " <>
                 "and fails with :enoent. Split it into cmd + args (see docs/lore.md L-0012)."

        args = config[:args] || []

        assert is_list(args) and Enum.all?(args, &is_binary/1),
               "#{Path.basename(@path)} predicate #{inspect(id)}: args must be a list of strings"
      end
    end
  end
end
