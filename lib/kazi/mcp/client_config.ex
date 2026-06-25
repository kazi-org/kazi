defmodule Kazi.MCP.ClientConfig do
  @moduledoc """
  The single source of truth for the canonical kazi MCP **client** config
  (T33.3, ADR-0044 decision 2).

  An MCP-speaking harness wires kazi as an MCP server with one stable command —
  the installed `kazi mcp` verb (ADR-0044 decision 1) over stdio:

      { "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }

  Every place that EMITS or DOCUMENTS this config — `kazi init --with-mcp`, the
  generated `install-skill` SKILL.md, `AGENTS.md`, and the README reference —
  derives the binary-verb form from this module (or, for the static docs, is
  asserted equal to `inline/0` by the coherence guard), so the config can never
  drift to the old `{ "command": "mix", "args": ["kazi.mcp"] }` JSON-CLI form.
  The Mix task `mix kazi.mcp` stays as the development entry point; the canonical
  client config references the installed BINARY verb.
  """

  # The server's key under "mcpServers" and the launch command. The installed
  # `kazi` binary's `mcp` verb starts the stdio MCP server (ADR-0044 decision 1).
  @server_name "kazi"
  @server_entry %{"command" => "kazi", "args" => ["mcp"]}
  @mcp_filename ".mcp.json"

  @doc "The server key kazi declares under `mcpServers` (`\"kazi\"`)."
  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @doc ~S"""
  The canonical server entry: `%{"command" => "kazi", "args" => ["mcp"]}` — the
  installed binary verb, not the `mix kazi.mcp` development shell-out.
  """
  @spec server_entry() :: map()
  def server_entry, do: @server_entry

  @doc ~S"""
  The full client config map: `%{"mcpServers" => %{"kazi" => server_entry()}}`.
  """
  @spec config() :: map()
  def config, do: %{"mcpServers" => %{@server_name => @server_entry}}

  @doc """
  The canonical config as pretty-printed JSON (no trailing newline). File writers
  add their own newline; doc snippets embed it verbatim.
  """
  @spec json() :: String.t()
  def json, do: Jason.encode!(config(), pretty: true)

  @doc ~S"""
  The compact, single-line config snippet the docs and generated skill embed:

      { "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }

  The coherence guard asserts every prose surface contains this exact string, so
  the "config everywhere" claim is load-bearing.
  """
  @spec inline() :: String.t()
  def inline, do: ~s({ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } })

  @doc """
  Additively merge the canonical `kazi` server entry into the `.mcp.json` in
  `dir`, preserving any servers or top-level keys already there and writing only
  when the file changes (idempotent). Mirrors `Kazi.Workspace`'s additive merge,
  but for the kazi MCP server rather than the code-graph server.

  Returns `{:ok, :created | :merged | :present, path}` (the written `.mcp.json`
  path) or `{:error, reason}` when an existing file cannot be parsed (we will not
  clobber a `.mcp.json` we cannot read).
  """
  @spec ensure_in_dir(String.t()) ::
          {:ok, :created | :merged | :present, String.t()} | {:error, term()}
  def ensure_in_dir(dir) when is_binary(dir) do
    path = Path.join(dir, @mcp_filename)

    with {:ok, existed?, existing} <- read_config(path) do
      servers = Map.get(existing, "mcpServers", %{})

      if Map.get(servers, @server_name) == @server_entry do
        {:ok, :present, path}
      else
        merged = Map.put(existing, "mcpServers", Map.put(servers, @server_name, @server_entry))

        with :ok <- write_config(path, merged) do
          {:ok, if(existed?, do: :merged, else: :created), path}
        end
      end
    end
  end

  # A missing file is an empty config (existed? false). A present-but-malformed
  # file is a hard error — never silently clobber a `.mcp.json` we cannot parse.
  @spec read_config(String.t()) :: {:ok, boolean(), map()} | {:error, term()}
  defp read_config(path) do
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

  # Write deterministically (pretty + trailing newline) so an unchanged config
  # always serialises to the same bytes.
  @spec write_config(String.t(), map()) :: :ok | {:error, term()}
  defp write_config(path, config) do
    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        with :ok <- File.mkdir_p(Path.dirname(path)) do
          File.write(path, json <> "\n")
        end

      {:error, reason} ->
        {:error, {:mcp_encode_failed, path, reason}}
    end
  end
end
