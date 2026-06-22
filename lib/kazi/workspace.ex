defmodule Kazi.Workspace do
  @moduledoc """
  Prepare the target workspace so each stateless `claude -p` dispatch starts
  *oriented* with cheap structural queries available (T4.5, UC-022; ADR-0010 §3).

  Two deterministic, idempotent preparations run before the harness is dispatched
  into the workspace:

    1. **Expose the graph MCP.** Ensure the workspace's `.mcp.json` declares the
       `code-review-graph` MCP server, so the agent's own exploration uses the
       ~10x-cheaper structural queries instead of grep+read (ADR-0010, the
       hybrid). The merge is **additive**: any servers already declared (and any
       other top-level keys) are preserved; writing twice yields the same file.

    2. **Keep the graph fresh.** When the workspace already carries a code graph
       (`.code-review-graph/graph.db`), refresh it before dispatch so the MCP
       serves up-to-date structure: run `code-review-graph detect-changes` and,
       if it reports drift, `code-review-graph update --skip-flows`. A workspace
       with no graph is left untouched (the agent falls back to file reads).

  ## The graph-command seam (`:graph_cmd`)

  The freshness step shells out to the real `code-review-graph` binary by
  default — a genuine implementation, not a stub. The single call site is
  isolated behind an injectable seam so tests never need the binary on PATH:

      Kazi.Workspace.prepare(workspace, graph_cmd: fn args, opts -> {output, 0} end)

  A `graph_cmd` is `fun([String.t()], keyword()) :: {Collectable.t(), exit_status}`
  with the same contract as `System.cmd/3` (the args list and a keyword carrying
  at least `cd:`). When absent, the real `System.cmd("code-review-graph", ...)`
  is used. This mirrors the `:integrator` / `:deploy_cmd` seams elsewhere in the
  runtime: a real default, injectable for hermetic tests.

  ## Result

  `prepare/2` returns `{:ok, summary}` where `summary` records what it did:

    * `:mcp` — `:created` (no `.mcp.json` existed) | `:merged` (entry added to an
      existing file) | `:present` (the entry was already there);
    * `:graph` — `:absent` (no graph in the workspace) | `:fresh` (graph present,
      already up to date) | `:updated` (graph present, refreshed).

  On a failure it could not work around it returns `{:error, reason}` (e.g. a
  malformed existing `.mcp.json`). Graph-freshness failures are non-fatal: the
  graph is an optimisation, so a `detect-changes`/`update` that errors is logged
  and reported as `graph: :error` rather than failing the dispatch.
  """

  require Logger

  @mcp_filename ".mcp.json"
  @graph_db_path ".code-review-graph/graph.db"
  @server_key "code-review-graph"
  @graph_command "code-review-graph"

  # The MCP server entry kazi declares for the workspace. `code-review-graph mcp`
  # starts the stdio MCP server the harness connects to (ADR-0010 §3).
  @server_entry %{
    "command" => @graph_command,
    "args" => ["mcp"]
  }

  @typedoc "What `prepare/2` did, per preparation step."
  @type summary :: %{
          mcp: :created | :merged | :present,
          graph: :absent | :fresh | :updated | :error
        }

  @doc """
  Prepare `workspace` for a harness dispatch: expose the graph MCP in its
  `.mcp.json` and refresh its code graph if one is present.

  Both steps are idempotent — running `prepare/2` twice over an already-prepared
  workspace leaves the `.mcp.json` byte-identical and re-checks (rather than
  re-derives) freshness.

  ## Options

    * `:graph_cmd` — the `System.cmd`-shaped seam used to run `code-review-graph`
      for the freshness step (see the moduledoc). Defaults to the real binary.

  Returns `{:ok, summary}` (see `t:summary/0`) or `{:error, reason}` when the MCP
  step could not complete (the freshness step never fails the call — it degrades
  to `graph: :error`).
  """
  @spec prepare(String.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def prepare(workspace, opts \\ []) when is_binary(workspace) and is_list(opts) do
    with {:ok, mcp} <- ensure_mcp_server(workspace) do
      {:ok, %{mcp: mcp, graph: ensure_graph_fresh(workspace, opts)}}
    end
  end

  # =============================================================================
  # Step 1: expose the graph MCP in .mcp.json (additive, idempotent)
  # =============================================================================

  # Read the workspace's .mcp.json (or start an empty config), add the
  # code-review-graph server under "mcpServers" without touching any other
  # servers or top-level keys, and write it back only when it changed.
  @spec ensure_mcp_server(String.t()) :: {:ok, :created | :merged | :present} | {:error, term()}
  defp ensure_mcp_server(workspace) do
    path = Path.join(workspace, @mcp_filename)

    with {:ok, existed?, config} <- read_mcp_config(path) do
      servers = Map.get(config, "mcpServers", %{})

      if Map.get(servers, @server_key) == @server_entry do
        {:ok, :present}
      else
        merged = Map.put(config, "mcpServers", Map.put(servers, @server_key, @server_entry))

        with :ok <- write_mcp_config(path, merged) do
          {:ok, if(existed?, do: :merged, else: :created)}
        end
      end
    end
  end

  # Returns {:ok, existed?, config_map}. A missing file is an empty config
  # (existed? false). A present-but-malformed file is a hard error — we will not
  # silently clobber a user's .mcp.json we cannot parse.
  @spec read_mcp_config(String.t()) :: {:ok, boolean(), map()} | {:error, term()}
  defp read_mcp_config(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, false, %{}}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, config} when is_map(config) -> {:ok, true, config}
          {:ok, _other} -> {:error, {:malformed_mcp_json, path}}
          {:error, reason} -> {:error, {:invalid_mcp_json, path, reason}}
        end

      {:error, reason} ->
        {:error, {:mcp_read_failed, path, reason}}
    end
  end

  # Write the config deterministically: sorted keys + a trailing newline so the
  # same config always serialises to the same bytes (idempotent writes).
  @spec write_mcp_config(String.t(), map()) :: :ok | {:error, term()}
  defp write_mcp_config(path, config) do
    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        with :ok <- File.mkdir_p(Path.dirname(path)) do
          File.write(path, json <> "\n")
        end

      {:error, reason} ->
        {:error, {:mcp_encode_failed, path, reason}}
    end
  end

  # =============================================================================
  # Step 2: keep the code graph fresh before dispatch (injectable seam)
  # =============================================================================

  # A workspace with no graph is left alone (`:absent`). With a graph, run
  # `detect-changes`; only run `update` when it reports drift. Any error from the
  # seam degrades to `:error` (graph freshness is an optimisation, never fatal to
  # the dispatch — ADR-0010, file-read fallback).
  @spec ensure_graph_fresh(String.t(), keyword()) :: :absent | :fresh | :updated | :error
  defp ensure_graph_fresh(workspace, opts) do
    if File.exists?(Path.join(workspace, @graph_db_path)) do
      graph_cmd = graph_cmd(opts)

      case run_graph(graph_cmd, ["detect-changes", "--brief"], workspace) do
        {:ok, output} ->
          if stale?(output), do: refresh_graph(graph_cmd, workspace), else: :fresh

        :error ->
          :error
      end
    else
      :absent
    end
  end

  @spec refresh_graph((... -> {Collectable.t(), non_neg_integer()}), String.t()) ::
          :updated | :error
  defp refresh_graph(graph_cmd, workspace) do
    case run_graph(graph_cmd, ["update", "--skip-flows"], workspace) do
      {:ok, _output} -> :updated
      :error -> :error
    end
  end

  # `detect-changes --brief` reports drift in its output; treat any mention of a
  # change/stale marker as "needs update". A clean graph reports none.
  @spec stale?(binary()) :: boolean()
  defp stale?(output) when is_binary(output) do
    String.match?(output, ~r/\b(stale|changed|change|dirty|modified|out[- ]?of[- ]?date)\b/i)
  end

  # Run one `code-review-graph` subcommand in the workspace via the seam. A
  # non-zero exit or a raised command (binary missing) is logged and reported as
  # :error so the caller degrades rather than crashes.
  @spec run_graph((... -> {Collectable.t(), non_neg_integer()}), [String.t()], String.t()) ::
          {:ok, binary()} | :error
  defp run_graph(graph_cmd, args, workspace) do
    case graph_cmd.(args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, to_string(output)}

      {output, status} ->
        Logger.warning(fn ->
          "kazi.workspace: code-review-graph #{Enum.join(args, " ")} exited #{status}: " <>
            String.trim(to_string(output))
        end)

        :error
    end
  rescue
    error ->
      Logger.warning(fn ->
        "kazi.workspace: could not run code-review-graph #{Enum.join(args, " ")}: " <>
          Exception.message(error)
      end)

      :error
  end

  # The freshness seam: an explicit `:graph_cmd` opt (tests) or the real
  # `code-review-graph` binary via System.cmd (production default — a genuine
  # implementation, not a stub).
  @spec graph_cmd(keyword()) :: (... -> {Collectable.t(), non_neg_integer()})
  defp graph_cmd(opts) do
    Keyword.get(opts, :graph_cmd, &default_graph_cmd/2)
  end

  @spec default_graph_cmd([String.t()], keyword()) :: {Collectable.t(), non_neg_integer()}
  defp default_graph_cmd(args, cmd_opts) do
    System.cmd(@graph_command, args, cmd_opts)
  end
end
