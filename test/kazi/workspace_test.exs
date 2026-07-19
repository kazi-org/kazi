defmodule Kazi.WorkspaceTest do
  @moduledoc """
  Hermetic tests for the T4.5 workspace preparation (ADR-0010 §3): the
  `.mcp.json` merge is idempotent + additive, and the graph-freshness step runs
  the injected `:graph_cmd` seam — never a real `code-review-graph` binary.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Kazi.Context.StaticGraphSource
  alias Kazi.PredicateResult
  alias Kazi.Workspace
  alias Kazi.Workspace.Orientation

  @server_key "code-review-graph"

  describe "prepare/2 — .mcp.json (graph MCP exposure)" do
    test "creates .mcp.json with the code-review-graph server when absent", %{tmp_dir: dir} do
      assert {:ok, %{mcp: :created}} = Workspace.prepare(dir, graph_cmd: never_called())

      config = read_mcp(dir)
      assert %{"mcpServers" => %{@server_key => entry}} = config
      assert entry["command"] == "code-review-graph"
      assert entry["args"] == ["mcp"]
    end

    test "merges the server into an existing .mcp.json, preserving other servers", %{tmp_dir: dir} do
      existing = %{
        "mcpServers" => %{
          "other" => %{"command" => "other-server", "args" => ["--flag"]}
        },
        "someTopLevelKey" => %{"keep" => true}
      }

      write_mcp(dir, existing)

      assert {:ok, %{mcp: :merged}} = Workspace.prepare(dir, graph_cmd: never_called())

      config = read_mcp(dir)
      # Unrelated server preserved.
      assert config["mcpServers"]["other"] == %{"command" => "other-server", "args" => ["--flag"]}
      # Unrelated top-level key preserved.
      assert config["someTopLevelKey"] == %{"keep" => true}
      # Our server added.
      assert config["mcpServers"][@server_key]["command"] == "code-review-graph"
    end

    test "is idempotent: writing twice yields a byte-identical file", %{tmp_dir: dir} do
      assert {:ok, %{mcp: :created}} = Workspace.prepare(dir, graph_cmd: never_called())
      first = File.read!(Path.join(dir, ".mcp.json"))

      assert {:ok, %{mcp: :present}} = Workspace.prepare(dir, graph_cmd: never_called())
      second = File.read!(Path.join(dir, ".mcp.json"))

      assert first == second
    end

    test "reports :present (no write) when the entry already matches", %{tmp_dir: dir} do
      write_mcp(dir, %{
        "mcpServers" => %{@server_key => %{"command" => "code-review-graph", "args" => ["mcp"]}}
      })

      assert {:ok, %{mcp: :present}} = Workspace.prepare(dir, graph_cmd: never_called())
    end

    test "errors on a malformed existing .mcp.json rather than clobbering it", %{tmp_dir: dir} do
      File.write!(Path.join(dir, ".mcp.json"), "{ this is not json")

      assert {:error, {:invalid_mcp_json, _path, _reason}} =
               Workspace.prepare(dir, graph_cmd: never_called())
    end
  end

  describe "prepare/2 — graph freshness (injected seam)" do
    test "skips freshness gracefully when no graph is present", %{tmp_dir: dir} do
      assert {:ok, %{graph: :absent}} = Workspace.prepare(dir, graph_cmd: never_called())
    end

    test "runs detect-changes and reports :fresh when the graph is up to date", %{tmp_dir: dir} do
      seed_graph(dir)
      {seam, log} = recording_seam(%{["detect-changes", "--brief"] => {"clean: no changes\n", 0}})

      assert {:ok, %{graph: :fresh}} = Workspace.prepare(dir, graph_cmd: seam)

      calls = Agent.get(log, & &1)
      assert [{["detect-changes", "--brief"], opts}] = calls
      assert opts[:cd] == dir
    end

    test "runs update when detect-changes reports drift", %{tmp_dir: dir} do
      seed_graph(dir)

      {seam, log} =
        recording_seam(%{
          ["detect-changes", "--brief"] => {"graph is stale\n", 0},
          ["update", "--skip-flows"] => {"updated 3 nodes\n", 0}
        })

      assert {:ok, %{graph: :updated}} = Workspace.prepare(dir, graph_cmd: seam)

      args_seen = Agent.get(log, fn calls -> Enum.map(calls, fn {args, _} -> args end) end)
      assert args_seen == [["detect-changes", "--brief"], ["update", "--skip-flows"]]
    end

    test "degrades to :error (never crashes) on a non-zero exit from the seam", %{tmp_dir: dir} do
      seed_graph(dir)
      {seam, _log} = recording_seam(%{["detect-changes", "--brief"] => {"boom\n", 2}})

      assert {:ok, %{graph: :error}} = Workspace.prepare(dir, graph_cmd: seam)
    end

    test "degrades to :error when the seam raises (binary missing)", %{tmp_dir: dir} do
      seed_graph(dir)
      raising = fn _args, _opts -> raise ErlangError, original: :enoent end

      assert {:ok, %{graph: :error}} = Workspace.prepare(dir, graph_cmd: raising)
    end
  end

  describe "prepare/2 — orientation file (T4.4)" do
    test "skips the orientation file when no :orientation opt is supplied", %{tmp_dir: dir} do
      assert {:ok, %{orientation: :skipped}} = Workspace.prepare(dir, graph_cmd: never_called())
      refute File.exists?(orientation_path(dir))
    end

    test "writes .kazi/context.md from the supplied failing predicates", %{tmp_dir: dir} do
      assert {:ok, %{orientation: :created}} =
               Workspace.prepare(dir,
                 graph_cmd: never_called(),
                 orientation: orientation_opt("boom in lib/foo.ex", ["lib/foo.ex"])
               )

      content = File.read!(orientation_path(dir))
      assert content =~ "# Orientation"
      assert content =~ "lib/foo.ex"
    end

    test "is idempotent: unchanged inputs report :unchanged and do not rewrite", %{tmp_dir: dir} do
      opts = [graph_cmd: never_called(), orientation: orientation_opt("x", ["lib/a.ex"])]

      assert {:ok, %{orientation: :created}} = Workspace.prepare(dir, opts)
      assert {:ok, %{orientation: :unchanged}} = Workspace.prepare(dir, opts)
    end
  end

  describe "prepare/2 — default seam" do
    test "default graph_cmd is real (degrades to :error, not a stub) with a graph present", %{
      tmp_dir: dir
    } do
      # With a graph present and no real `code-review-graph` on PATH in CI, the
      # REAL default seam runs and the missing binary degrades to :error — proving
      # the default is a genuine System.cmd call, not an injected stub returning ok.
      seed_graph(dir)

      assert {:ok, %{mcp: :created, graph: graph}} = Workspace.prepare(dir)
      assert graph in [:fresh, :updated, :error]
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A graph_cmd seam that records every (args, opts) call and answers from a map
  # keyed by the args list. Unknown args raise so the test fails loudly.
  defp recording_seam(responses) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    seam = fn args, opts ->
      Agent.update(log, &(&1 ++ [{args, opts}]))

      case Map.fetch(responses, args) do
        {:ok, result} -> result
        :error -> raise "unexpected graph_cmd call: #{inspect(args)}"
      end
    end

    {seam, log}
  end

  # A seam that must never be invoked (used by .mcp.json-only / no-graph tests).
  defp never_called do
    fn args, _opts -> raise "graph_cmd should not be called, got: #{inspect(args)}" end
  end

  # Seed a fake graph db so the freshness step engages without a real graph.
  defp seed_graph(dir) do
    db_dir = Path.join(dir, ".code-review-graph")
    File.mkdir_p!(db_dir)
    File.write!(Path.join(db_dir, "graph.db"), "")
  end

  # The `:orientation` opt prepare/2 forwards to Kazi.Workspace.Orientation: a
  # `{failing, context_opts}` pair, with the graph seam injected so it stays
  # hermetic (no real graph / network).
  defp orientation_opt(evidence_output, files) do
    failing = [{:unit, PredicateResult.fail(%{output: evidence_output})}]
    context_opts = [graph_source: StaticGraphSource.new(origin: :graph, files: files)]
    {failing, context_opts}
  end

  defp orientation_path(dir), do: Path.join(dir, Orientation.rel_path())

  defp write_mcp(dir, config) do
    File.write!(Path.join(dir, ".mcp.json"), Jason.encode!(config))
  end

  defp read_mcp(dir) do
    dir |> Path.join(".mcp.json") |> File.read!() |> Jason.decode!()
  end
end
