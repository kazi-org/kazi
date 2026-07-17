defmodule Kazi.Providers.DocsUpdatedTest do
  @moduledoc """
  T44.8 (ADR-0034): the `:docs_updated` gate — a surface-change heuristic
  (ported from the T29.1 docs-with-code CI check). A user-facing surface change
  must ride with a docs change OR a `[no-docs] <reason>` commit-message marker.

  Real git boundary (Tier 2): a fixture repo with real commits + real `git diff` /
  `git log` scanning, never synthetic strings.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.DocsUpdated

  test "a surface change with NO docs and NO marker FAILS, naming the surface files" do
    dir = seed_repo()
    base = head(dir)

    write(dir, "lib/kazi/providers/widget.ex", "defmodule Widget do\nend\n")
    commit(dir, "feat: a new widget provider")

    result = evaluate(dir, base)

    assert result.status == :fail
    assert result.evidence.reason == :missing_docs
    assert result.evidence.surface_files == ["lib/kazi/providers/widget.ex"]
    assert result.evidence.count == 1
  end

  test "the SAME surface change PLUS a docs change PASSES" do
    dir = seed_repo()
    base = head(dir)

    write(dir, "lib/kazi/providers/widget.ex", "defmodule Widget do\nend\n")
    write(dir, "docs/widget.md", "# Widget\n")
    commit(dir, "feat: widget provider + docs")

    result = evaluate(dir, base)

    assert result.status == :pass
    assert result.evidence.reason == :docs_present
    assert result.evidence.applicable == true
    assert "lib/kazi/providers/widget.ex" in result.evidence.surface_files
  end

  test "the SAME surface change PLUS a [no-docs] marker PASSES, reason in evidence" do
    dir = seed_repo()
    base = head(dir)

    write(dir, "lib/kazi/providers/widget.ex", "defmodule Widget do\nend\n")
    commit(dir, "refactor: rename widget internals\n\n[no-docs] internal-only provider rename")

    result = evaluate(dir, base)

    assert result.status == :pass
    assert result.evidence.reason == :no_docs_marker
    assert result.evidence.justification == "internal-only provider rename"
  end

  test "a README change counts as docs for the same surface change" do
    dir = seed_repo()
    base = head(dir)

    write(dir, "lib/kazi/cli.ex", "defmodule Kazi.CLI do\nend\n")
    write(dir, "README.md", "seed\nnew flag docs\n")
    commit(dir, "feat: new cli flag + README")

    result = evaluate(dir, base)
    assert result.status == :pass
    assert result.evidence.reason == :docs_present
  end

  test "a NON-surface diff passes VACUOUSLY (the gate does not apply)" do
    dir = seed_repo()
    base = head(dir)

    write(dir, "lib/kazi/internal/widget.ex", "defmodule Internal do\nend\n")
    commit(dir, "chore: internal helper, no surface change")

    result = evaluate(dir, base)

    assert result.status == :pass
    assert result.evidence.applicable == false
    assert result.evidence.reason == :no_surface_change
  end

  test "a non-git workspace is an :error, not a false :pass" do
    dir = Path.join(System.tmp_dir!(), "kazi-docs-nogit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = evaluate(dir, nil)
    assert result.status == :error
    assert result.evidence.reason == :not_a_git_repo
  end

  describe "wiring (loader + schema)" do
    test "the loader maps the `docs_updated` provider string to :docs_updated" do
      data = %{"id" => "g", "predicate" => [%{"id" => "gate", "provider" => "docs_updated"}]}
      assert {:ok, %Kazi.Goal{predicates: [predicate]}} = Kazi.Goal.Loader.from_map(data)
      assert predicate.kind == :docs_updated
    end

    test "the shipped priv/examples/docs_updated.toml loads" do
      path = Path.join([File.cwd!(), "priv", "examples", "docs_updated.toml"])
      assert {:ok, %Kazi.Goal{predicates: predicates}} = Kazi.Goal.Loader.load(path)
      assert Enum.any?(predicates, &(&1.kind == :docs_updated))
    end

    test "`kazi schema docs_updated` has a documented config schema" do
      assert {:ok, schema} = Kazi.Predicate.Schema.fetch("docs_updated")
      assert schema.kind == "docs_updated"
      assert schema.description != ""
      assert "docs_updated" in Kazi.Predicate.Schema.kinds()

      names = schema.keys |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["base", "doc_patterns", "surface_patterns"]
    end
  end

  # ===========================================================================
  # helpers — real git
  # ===========================================================================

  defp evaluate(workspace, base) do
    config = if base, do: %{base: base}, else: %{}

    DocsUpdated.evaluate(Predicate.new(:gate, :docs_updated, config: config), %{
      workspace: workspace
    })
    |> tap(fn %PredicateResult{} -> :ok end)
  end

  defp seed_repo do
    dir = Path.join(System.tmp_dir!(), "kazi-docs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    git!(dir, ["init", "-q", "--initial-branch=main"])
    git!(dir, ["config", "user.email", "t@kazi"])
    git!(dir, ["config", "user.name", "kazi"])
    git!(dir, ["config", "commit.gpgsign", "false"])

    write(dir, "README.md", "seed\n")
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
