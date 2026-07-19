defmodule Kazi.Harness.DispatchSurface do
  @moduledoc """
  The **minimal default tool/MCP surface** kazi hands a reconcile dispatch
  (T36.2, ADR-0047 decision 1).

  ADR-0008 makes kazi own the inner harness's context; ADR-0010 §3 injects the
  orientation/graph MCP server into the workspace. This module decides *which*
  of that surface the inner harness actually sees per dispatch: by default a
  reconcile dispatch is restricted to **the MCP servers kazi injected** plus the
  **standard edit/shell tools** the agent needs to fix predicates — NOT the
  ambient set (the operator's globally-configured MCP servers, every tool the
  CLI ships). Fewer irrelevant tool schemas in context is a strict, low-risk
  token win (ADR-0047 "Context"): `--allowed-tools` governs *approval* but does
  not necessarily remove a tool's schema from the model's context, whereas
  `--strict-mcp-config` + a scoped `--mcp-config` + a `--tools` allow-list
  actually shrink what the harness loads.

  The surface is rendered as the T36.1 economy opts the Claude profile already
  maps to flags (`Kazi.Harness.Profiles.Claude`):

    * `:strict_mcp_config` → `--strict-mcp-config` — ignore EVERY ambient MCP
      config; use only the `--mcp-config` files passed here. This is what keeps
      an irrelevant ambient server's schemas out of the prompt.
    * `:mcp_config` → `--mcp-config <file> …` — the workspace `.mcp.json` kazi
      wrote (the orientation/graph server). Because `--strict-mcp-config`
      disables auto-discovery of that same file, it MUST be passed explicitly or
      the injected server would vanish too.
    * `:tools` → `--tools <tool> …` — the standard edit/shell tools PLUS an
      `mcp__<server>` ref per injected server, so the injected MCP tools stay in
      the allow-list rather than being excluded by it.

  ## Never empty

  The default surface is ALWAYS "injected + standard edit/shell", never an empty
  set (ADR-0047 risk note): even with no injected MCP servers the `:tools`
  list is the `standard_tools/0` floor, so the agent can always read/edit/run to
  fix predicates. A too-aggressive empty surface would strand the agent.

  ## E35 seam

  `injected_servers/1` is the single list the surface consumes. Today it is the
  orientation/graph server only; the E35 `Kazi.ContextStore` (search-only mode,
  ADR-0045) plugs in by appending its `{name, config}` entry there once T35.1
  lands — no change to the rendering logic. See `injected_servers/1`.
  """

  alias Kazi.Context.Tier
  alias Kazi.ContextStore.GistInit
  alias Kazi.Harness.Profile

  # The context-store MCP tool inner harnesses MAY call (ADR-0045 §7): search, not
  # index. Inner harnesses search; only the outer controller indexes (T35.9).
  @gist_search_tool "gist_search"

  # The standard edit/shell tools every reconcile dispatch needs to fix
  # predicates: read/inspect, edit/write, run, and find. This is the NEVER-EMPTY
  # floor — the default surface is at least these tools even when no MCP server
  # is injected (ADR-0047: the default is "injected + standard edit/shell", never
  # an empty set).
  @standard_tools ~w(Read Edit Write Bash Glob Grep)

  # The orientation/graph MCP server kazi injects into every prepared workspace
  # (ADR-0010 §3): `code-review-graph`, declared in the workspace `.mcp.json` by
  # `Kazi.Workspace.prepare/2`. Kept in lock-step with `Kazi.Workspace`'s own
  # `@server_key` / `@mcp_filename`.
  @graph_server "code-review-graph"
  @mcp_filename ".mcp.json"

  @typedoc """
  An injected MCP server. `:tools`, when present, is the explicit allow-list of
  `mcp__<server>__<tool>` refs for that server (a SCOPED subset); absent, the bare
  `mcp__<server>` ref allows all of the server's tools. The context-store server
  uses `:tools` to expose `gist_search` only — inner harnesses search, they do not
  index, by default (T35.9, ADR-0045 §7).
  """
  @type injected_server :: %{
          required(:name) => String.t(),
          required(:config) => String.t(),
          optional(:tools) => [String.t()]
        }

  @doc """
  The minimal-surface opts to merge into a reconcile dispatch's adapter opts, or
  `[]` when the dispatch should be left untouched.

  Returns `[]` (no surface restriction, byte-identical to the pre-T36.2 dispatch)
  when EITHER:

    * `adapter_opts[:dispatch_surface]` is `:ambient` — the explicit OFF switch:
      the operator/benchmark asked for the pre-T36.2 ambient surface (every
      configured MCP server + the harness's default tool set), so the minimal
      surface is suppressed. This is the `tool-surface off` arm the T36.5
      benchmark measures against the `:minimal` default (ADR-0047). Any value
      other than `:ambient` (including the absent default) keeps the minimal
      surface, and

    * `workspace` is a real path (a workspaceless loop has nowhere to scope the
      MCP config), AND
    * the resolved harness profile carried in `adapter_opts[:profile]` advertises
      the T36.1 economy opts (`:strict_mcp_config` / `:mcp_config` / `:tools`).
      This is the per-profile opt-in ADR-0047 mandates — only Claude declares
      them today, so a non-Claude harness (or a test double with no `:profile`)
      is unaffected and stays back-compatible.

  When both hold, returns `build/1` over the workspace's `injected_servers/1`,
  **tier-filtered**: the live code-review-graph MCP server is a TIER-2 feature
  (ADR-0047 §2), so the active `Kazi.Context.Tier` (`adapter_opts[:context_tier]`,
  default 1) DROPS it below tier 2. At the default tier 1 the agent gets the
  cached orientation TEXT (assembled separately by `Kazi.Context`) but no live
  graph MCP; tier ≥ 2 exposes it. The standard edit/shell tool floor is always
  present — the surface is never empty (the agent can always read/edit/run).

  The caller merges this UNDER its explicit adapter opts, so an operator/goal
  that set `:tools` (etc.) still wins.
  """
  @spec minimal_default(term(), keyword()) :: keyword()
  def minimal_default(workspace, adapter_opts) when is_list(adapter_opts) do
    if not ambient?(adapter_opts) and is_binary(workspace) and surface_supported?(adapter_opts) do
      workspace
      |> injected_servers()
      |> tier_filter(Tier.resolve(adapter_opts))
      |> apply_inner_index_policy(adapter_opts)
      |> build()
    else
      []
    end
  end

  def minimal_default(_workspace, _adapter_opts), do: []

  @doc """
  Render the minimal-surface economy opts for an explicit injected-server list.
  PURE — no workspace IO, no profile gate; the policy lives in `minimal_default/2`.

  The `:tools` allow-list is the standard edit/shell floor PLUS one `mcp__<name>`
  ref per injected server (so the injected MCP tools survive the allow-list), and
  `:mcp_config` is the de-duplicated set of injected config files. With an empty
  injected list the surface is still the standard tools + `--strict-mcp-config`
  (no MCP servers, but never an empty tool set).
  """
  @spec build([injected_server()]) :: keyword()
  def build(injected) when is_list(injected) do
    mcp_configs = injected |> Enum.map(& &1.config) |> Enum.uniq()
    mcp_tools = Enum.flat_map(injected, &server_tool_refs/1)

    [
      strict_mcp_config: true,
      mcp_config: mcp_configs,
      tools: @standard_tools ++ mcp_tools
    ]
  end

  # A server's allow-list refs: its SCOPED `:tools` when present (e.g. the
  # context-store server's `gist_search`-only ref), else the bare `mcp__<name>`
  # (all of that server's tools).
  @spec server_tool_refs(injected_server()) :: [String.t()]
  defp server_tool_refs(%{tools: tools}) when is_list(tools) and tools != [], do: tools
  defp server_tool_refs(%{name: name}), do: ["mcp__#{name}"]

  @doc """
  The MCP servers kazi injects into `workspace`, as `{name, config}` entries.

  Today this is the orientation/graph server (`code-review-graph`) declared in
  the workspace `.mcp.json`. **E35 seam:** the `Kazi.ContextStore` search-only
  server (ADR-0045) is appended HERE once T35.1 lands —
  e.g. `%{name: "kazi-context-store", config: <its config path>}` — and the rest
  of this module renders it with no further change.
  """
  @spec injected_servers(String.t()) :: [injected_server()]
  def injected_servers(workspace) when is_binary(workspace) do
    mcp_path = Path.join(workspace, @mcp_filename)
    [%{name: @graph_server, config: mcp_path}] ++ context_store_server(mcp_path)
  end

  # E35 (T35.9, ADR-0045 §7): when the workspace `.mcp.json` declares the Gist
  # context-store server (written by `kazi init --with-gist`), expose it to the
  # inner harness SEARCH-ONLY — its allow-list ref is scoped to `gist_search`, so
  # `gist_index` is NOT allowed: inner harnesses search, only the outer controller
  # indexes. A goal/operator can widen this (allow indexing) via the
  # `:inner_index` opt — see `apply_inner_index_policy/2`. Absent the gist server
  # from `.mcp.json`, nothing is injected (back-compat).
  @spec context_store_server(String.t()) :: [injected_server()]
  defp context_store_server(mcp_path) do
    name = GistInit.gist_server_name()

    if mcp_declares_server?(mcp_path, name) do
      [%{name: name, config: mcp_path, tools: ["mcp__#{name}__#{@gist_search_tool}"]}]
    else
      []
    end
  end

  @spec mcp_declares_server?(String.t(), String.t()) :: boolean()
  defp mcp_declares_server?(mcp_path, name) do
    with {:ok, body} <- File.read(mcp_path),
         {:ok, %{"mcpServers" => servers}} when is_map(servers) <- Jason.decode(body) do
      Map.has_key?(servers, name)
    else
      _ -> false
    end
  end

  # T35.9: widen the search-only context-store server to its full tool set (allow
  # `gist_index`) when the goal/operator opted in via `:inner_index`. Dropping a
  # server's scoped `:tools` makes `build/1` emit the bare `mcp__<name>` ref.
  @spec apply_inner_index_policy([injected_server()], keyword()) :: [injected_server()]
  defp apply_inner_index_policy(servers, adapter_opts) do
    if Keyword.get(adapter_opts, :inner_index) == true do
      Enum.map(servers, &Map.delete(&1, :tools))
    else
      servers
    end
  end

  @doc "The standard edit/shell tool floor — the never-empty surface."
  @spec standard_tools() :: [String.t()]
  def standard_tools, do: @standard_tools

  @doc """
  The tool-surface mode the adapter opts select: `:ambient` when
  `:dispatch_surface` is explicitly `:ambient` (the OFF switch — pre-T36.2 full
  surface), else `:minimal` (the default). The label the T36.5 benchmark records
  per arm.

  ## Examples

      iex> Kazi.Harness.DispatchSurface.surface_mode([])
      :minimal
      iex> Kazi.Harness.DispatchSurface.surface_mode(dispatch_surface: :ambient)
      :ambient
  """
  @spec surface_mode(keyword()) :: :minimal | :ambient
  def surface_mode(adapter_opts) when is_list(adapter_opts) do
    if ambient?(adapter_opts), do: :ambient, else: :minimal
  end

  def surface_mode(_), do: :minimal

  # The explicit OFF switch: `:dispatch_surface, :ambient` suppresses the minimal
  # surface so the dispatch carries the pre-T36.2 ambient set. Any other value
  # (or absence) keeps the minimal default.
  @spec ambient?(keyword()) :: boolean()
  defp ambient?(adapter_opts), do: Keyword.get(adapter_opts, :dispatch_surface) == :ambient

  # T36.3 (ADR-0047 §2): drop the live code-review-graph MCP server below tier 2 —
  # it is the tier-2 "+ graph" feature. Other injected servers (e.g. the E35
  # search-only context store) are NOT graph and stay regardless of tier. Tier ≥ 2
  # keeps the full injected set.
  @spec tier_filter([injected_server()], Tier.t()) :: [injected_server()]
  defp tier_filter(servers, tier) do
    if Tier.graph?(tier),
      do: servers,
      else: Enum.reject(servers, &(&1.name == @graph_server))
  end

  # The per-profile opt-in: the surface is applied only when the resolved profile
  # in `adapter_opts[:profile]` advertises the economy opts (ADR-0047 "opt-in per
  # profile with a version-gated capability check"). A test double or non-Claude
  # harness that carries no `%Profile{}` (or one without these opts) is left
  # alone.
  @spec surface_supported?(keyword()) :: boolean()
  defp surface_supported?(adapter_opts) do
    case Keyword.get(adapter_opts, :profile) do
      %Profile{supported_opts: supported} when is_list(supported) ->
        :strict_mcp_config in supported and :mcp_config in supported and :tools in supported

      _ ->
        false
    end
  end
end
