defmodule Kazi.CLIRunParallelJsonTest do
  @moduledoc """
  T21.8 (ADR-0027 + ADR-0023): `kazi run --parallel` routes to the PARALLEL
  SCHEDULER (`Kazi.Scheduler.run_goals/2`) instead of the serial loop, and under
  `--json` emits the VERSIONED COLLECTIVE result — per-partition status + the
  overall collective verdict + a `next_action` hint + `schema_version` —
  documented in `docs/schemas/collective-result.md`.

  These are Tier-2 boundary tests: they drive the REAL CLI exec core
  (`Kazi.CLI.run/2`) against a goal-file on disk, with the SCHEDULER's injectable
  seams pointed at hermetic stubs — an injected graph source (a per-term file
  mapping, no repo-map/network) and an injected reconciler (a chosen terminal
  status, no real harness, lease, or worktree). Output is captured with
  `ExUnit.CaptureIO`; each verdict yields the documented object and exit code.

  A single goal-file loads ONE goal, so it partitions to a SINGLE partition (the
  serial degenerate, ADR-0027 step 1): the collective verdict equals that
  partition's status, surfaced through the collective shape.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Repo

  # A hermetic graph source: maps each partition term to a fixed file list, so
  # partitioning never reads the repo-map or the filesystem (mirrors the
  # scheduler's own run_goals_test TermSource).
  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.fetch!(opts, :mapping)

      files =
        terms
        |> Enum.flat_map(&Map.get(mapping, &1, []))
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  # The scheduler seams a hermetic parallel run injects: a static graph source, a
  # stub reconciler returning `status`, and a short terminal timeout. No lease /
  # worktree opts ⇒ the scheduler skips both layers (a degenerate single-partition
  # run needs neither), so no real git repo is required.
  defp parallel_inject_opts(status) do
    [
      graph_source: TermSource.new(%{"a" => ["lib/a.ex"]}),
      reconciler: fn _partition, _worktree_path -> status end,
      reconcile_timeout: 5_000
    ]
  end

  # Check out the SQL sandbox so the CLI's read-model boot finds an owned
  # connection (the run still does not depend on persistence — the injected
  # reconciler decides the verdict — but this keeps the suite output clean rather
  # than logging a degraded-persistence warning).
  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Tier 1 — `--parallel` argv boundary
  # ===========================================================================

  describe "parse/1 — run --parallel" do
    test "run carries --parallel through to its opts" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws", "--parallel"])

      assert opts[:parallel] == true
      assert opts[:parallelism] == nil
    end

    test "run --parallel N records the optional concurrency hint" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws", "--parallel", "4"])

      assert opts[:parallel] == true
      assert opts[:parallelism] == 4
    end

    test "without --parallel the flag defaults to false (serial is the default)" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["apply", "goal.toml", "--workspace", "/tmp/ws"])

      assert opts[:parallel] == false
    end

    test "a bare integer after --parallel is consumed, not left as a stray positional" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse([
                 "apply",
                 "goal.toml",
                 "--parallel",
                 "2",
                 "--workspace",
                 "/tmp/ws",
                 "--json"
               ])

      assert opts[:parallel] == true
      assert opts[:parallelism] == 2
      assert opts[:json] == true
    end
  end

  # ===========================================================================
  # Tier 2 — run --parallel --json yields the documented COLLECTIVE object
  # ===========================================================================

  describe "run --parallel --json — collective converged" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "emits a single COLLECTIVE JSON object with per-partition status, exit 0",
         %{tmp_dir: tmp_dir} do
      goal_file = write_parallel_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                   parallel_inject_opts(:converged)
                 ) == 0
        end)

      # VALID JSON only — the whole stdout decodes as one object, no human prose.
      assert {:ok, payload} = Jason.decode(String.trim(out))
      refute out =~ "COLLECTIVE"
      refute out =~ "partitions:"

      assert payload["schema_version"] == 2
      assert payload["goal_id"] == "cli-parallel"
      assert payload["collective"] == "converged"
      assert payload["next_action"] == "done"

      # A single goal-file ⇒ exactly one partition (the serial degenerate),
      # carrying its goal id and the partition's terminal status.
      assert [partition] = payload["partitions"]
      assert partition["status"] == "converged"
      assert partition["goal_ids"] == ["cli-parallel"]
      assert is_binary(partition["partition_id"]) and partition["partition_id"] != ""
    end
  end

  describe "run --parallel --json — collective stuck" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "a non-converged partition yields collective stuck + investigate, exit 1",
         %{tmp_dir: tmp_dir} do
      goal_file = write_parallel_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                   parallel_inject_opts(:stuck)
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 2
      assert payload["collective"] == "stuck"
      assert payload["next_action"] == "investigate"
      assert [%{"status" => "stuck"}] = payload["partitions"]
    end
  end

  describe "run --parallel --json — collective over_budget" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "an over-budget partition yields collective over_budget + raise_budget, exit 1",
         %{tmp_dir: tmp_dir} do
      goal_file = write_parallel_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                   parallel_inject_opts(:over_budget)
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["collective"] == "over_budget"
      assert payload["next_action"] == "raise_budget"
      assert [%{"status" => "over_budget"}] = payload["partitions"]
    end
  end

  # ===========================================================================
  # Tier 2 — the human surface (no --json) is the collective block, not JSON
  # ===========================================================================

  describe "run --parallel (human) — collective block" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "without --json a human collective block is printed (not JSON)",
         %{tmp_dir: tmp_dir} do
      goal_file = write_parallel_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--parallel"],
                   parallel_inject_opts(:converged)
                 ) == 0
        end)

      assert out =~ "COLLECTIVE CONVERGED"
      assert out =~ "partitions: 1"
      assert out =~ "cli-parallel"
      # NOT a JSON object on stdout.
      assert {:error, %Jason.DecodeError{}} = Jason.decode(String.trim(out))
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  # A goal-file whose goal declares a partition term `a` (so the injected graph
  # source resolves its blast radius hermetically). The predicate is irrelevant —
  # the injected reconciler decides the terminal status — but a goal needs at least
  # one failing predicate to be non-vacuous at load.
  defp write_parallel_goal_file(tmp_dir) do
    path = Path.join(tmp_dir, "parallel_goal.toml")

    File.write!(path, """
    id = "cli-parallel"
    name = "CLI run --parallel collective"

    [scope]
    workspace = "#{tmp_dir}"

    [metadata]
    partition_terms = ["a"]

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_created.txt"]
    """)

    path
  end
end
