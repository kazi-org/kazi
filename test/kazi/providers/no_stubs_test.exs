defmodule Kazi.Providers.NoStubsTest do
  @moduledoc """
  T44.6: the `:no_stubs` provider scans the goal's diff-vs-base for
  stub/placeholder markers on ADDED lines in NON-TEST files. Real git boundary
  (Tier 2): an actual fixture repo with real commits + a real `git diff`, never a
  synthetic diff string.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.NoStubs

  test "a stub added in a production file FAILS, naming the exact file:line" do
    dir = seed_repo(%{"lib/widget.ex" => "defmodule Widget do\nend\n"})
    base = head(dir)

    # The agent adds a stub in a production file (a second commit).
    write(dir, "lib/widget.ex", "defmodule Widget do\n  # Stub: not implemented yet\nend\n")
    commit(dir, "add widget")

    result = evaluate(dir, base)

    assert result.status == :fail
    assert result.evidence.count == 1
    assert [%{file: "lib/widget.ex", line: 2, pattern: "stub"} = hit] = result.evidence.hits
    assert hit.snippet =~ "Stub"
  end

  test "the SAME stub pattern in a test file PASSES (test files are exempt)" do
    dir = seed_repo(%{"lib/widget.ex" => "defmodule Widget do\nend\n"})
    base = head(dir)

    # Stubs/mocks are legitimate in tests.
    write(dir, "test/widget_test.exs", "defmodule WidgetTest do\n  # Mock the client here\nend\n")
    commit(dir, "add widget test with a mock")

    result = evaluate(dir, base)

    assert result.status == :pass
    assert result.evidence.hits == 0
  end

  test "a clean diff (no stub markers anywhere) PASSES" do
    dir = seed_repo(%{"lib/widget.ex" => "defmodule Widget do\nend\n"})
    base = head(dir)

    write(dir, "lib/widget.ex", "defmodule Widget do\n  def add(a, b), do: a + b\nend\n")
    commit(dir, "implement add")

    result = evaluate(dir, base)

    assert result.status == :pass
    assert result.evidence.hits == 0
    assert result.evidence.scanned_files == 1
  end

  test "multiple markers across production files are all named, test hits excluded" do
    dir = seed_repo(%{"lib/a.ex" => "x\n", "lib/b.ex" => "y\n"})
    base = head(dir)

    write(dir, "lib/a.ex", "x\n# TODO: finish\n")
    write(dir, "lib/b.ex", "y\ndef f, do: :placeholder\n")
    write(dir, "test/a_test.exs", "# FIXME: flaky\n")
    commit(dir, "changes")

    result = evaluate(dir, base)

    assert result.status == :fail
    patterns = result.evidence.hits |> Enum.map(& &1.pattern) |> Enum.sort()
    assert patterns == ["placeholder", "todo"]
    files = result.evidence.hits |> Enum.map(& &1.file) |> Enum.sort() |> Enum.uniq()
    assert files == ["lib/a.ex", "lib/b.ex"]
  end

  test "an :exclude prefix exempts a production path" do
    dir = seed_repo(%{"lib/widget.ex" => "x\n"})
    base = head(dir)

    write(dir, "priv/examples/demo.ex", "# TODO: a demo\n")
    commit(dir, "add demo example")

    result = evaluate(dir, base, %{exclude: ["priv/examples/"]})
    assert result.status == :pass
  end

  test "a non-git workspace is an :error, not a false :pass" do
    dir = Path.join(System.tmp_dir!(), "kazi-nostubs-nogit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = evaluate(dir, nil)
    assert result.status == :error
    assert result.evidence.reason == :not_a_git_repo
  end

  describe "wiring (loader + schema)" do
    test "the loader maps the `no_stubs` provider string to the :no_stubs kind" do
      data = %{
        "id" => "g",
        "predicate" => [%{"id" => "gate", "provider" => "no_stubs"}]
      }

      assert {:ok, %Kazi.Goal{predicates: [predicate]}} = Kazi.Goal.Loader.from_map(data)
      assert predicate.kind == :no_stubs
    end

    test "the shipped priv/examples/no_stubs.toml loads" do
      path = Path.join([File.cwd!(), "priv", "examples", "no_stubs.toml"])
      assert {:ok, %Kazi.Goal{predicates: predicates}} = Kazi.Goal.Loader.load(path)
      assert Enum.any?(predicates, &(&1.kind == :no_stubs))
    end

    test "`kazi schema no_stubs` has a documented config schema" do
      assert {:ok, schema} = Kazi.Predicate.Schema.fetch("no_stubs")
      assert schema.kind == "no_stubs"
      assert schema.description != ""
      assert "no_stubs" in Kazi.Predicate.Schema.kinds()

      names = schema.keys |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["base", "exclude", "patterns"]

      for key <- schema.keys do
        assert key.name != "" and key.type != "" and key.description != ""
        assert is_boolean(key.required)
      end
    end
  end

  # ===========================================================================
  # helpers — real git
  # ===========================================================================

  defp evaluate(workspace, base, extra \\ %{}) do
    config = if(base, do: %{base: base}, else: %{}) |> Map.merge(extra)

    NoStubs.evaluate(Predicate.new(:gate, :no_stubs, config: config), %{workspace: workspace})
    |> tap(fn %PredicateResult{} -> :ok end)
  end

  defp seed_repo(files) do
    dir = Path.join(System.tmp_dir!(), "kazi-nostubs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    git!(dir, ["init", "-q", "--initial-branch=main"])
    git!(dir, ["config", "user.email", "t@kazi"])
    git!(dir, ["config", "user.name", "kazi"])
    git!(dir, ["config", "commit.gpgsign", "false"])

    Enum.each(files, fn {rel, contents} -> write(dir, rel, contents) end)
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-qm", "seed"])
    dir
  end

  defp write(dir, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp commit(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-qm", message])
  end

  defp head(dir) do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    String.trim(sha)
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    :ok
  end
end
