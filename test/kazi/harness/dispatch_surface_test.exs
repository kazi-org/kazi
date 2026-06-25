defmodule Kazi.Harness.DispatchSurfaceTest do
  # Pure surface computation — no subprocess, no shared state.
  use ExUnit.Case, async: true

  alias Kazi.Harness.DispatchSurface
  alias Kazi.Harness.Profile
  alias Kazi.Harness.Profiles.Claude
  alias Kazi.Harness.Registry

  @workspace "/tmp/kazi-ws"
  @injected_config Path.join(@workspace, ".mcp.json")

  describe "build/1 — the minimal-surface economy opts (T36.2, ADR-0047 §1)" do
    test "renders strict-config + scoped mcp-config + standard tools and the mcp ref" do
      opts = DispatchSurface.build([%{name: "code-review-graph", config: @injected_config}])

      assert Keyword.get(opts, :strict_mcp_config) == true
      assert Keyword.get(opts, :mcp_config) == [@injected_config]
      # The standard edit/shell floor PLUS one mcp__<server> ref, so the injected
      # MCP tools survive the allow-list rather than being excluded by it.
      assert Keyword.get(opts, :tools) ==
               DispatchSurface.standard_tools() ++ ["mcp__code-review-graph"]
    end

    test "the standard tool floor is real edit/shell tools (not empty)" do
      assert DispatchSurface.standard_tools() == ~w(Read Edit Write Bash Glob Grep)
    end

    test "de-duplicates two servers sharing one mcp-config file but keeps both tool refs" do
      # The E35 store may declare its server in the SAME workspace .mcp.json as the
      # graph server: one config file, two server tool refs.
      injected = [
        %{name: "code-review-graph", config: @injected_config},
        %{name: "kazi-context-store", config: @injected_config}
      ]

      opts = DispatchSurface.build(injected)

      assert Keyword.get(opts, :mcp_config) == [@injected_config]

      assert Keyword.get(opts, :tools) ==
               DispatchSurface.standard_tools() ++
                 ["mcp__code-review-graph", "mcp__kazi-context-store"]
    end

    test "an empty injected list is NEVER an empty surface — still the standard tools" do
      opts = DispatchSurface.build([])

      assert Keyword.get(opts, :strict_mcp_config) == true
      assert Keyword.get(opts, :mcp_config) == []
      # The never-empty floor: the agent can always read/edit/run to fix predicates.
      assert Keyword.get(opts, :tools) == DispatchSurface.standard_tools()
      refute Keyword.get(opts, :tools) == []
    end
  end

  describe "injected_servers/1 — the kazi-injected MCP servers (E35 seam)" do
    test "is the orientation/graph server declared in the workspace .mcp.json" do
      assert DispatchSurface.injected_servers(@workspace) == [
               %{name: "code-review-graph", config: @injected_config}
             ]
    end
  end

  describe "minimal_default/2 — the per-dispatch policy gate" do
    test "applies the surface for a Claude-profile dispatch with a workspace" do
      {:ok, profile} = Registry.fetch(:claude)

      opts = DispatchSurface.minimal_default(@workspace, profile: profile)

      assert Keyword.get(opts, :strict_mcp_config) == true
      assert Keyword.get(opts, :mcp_config) == [@injected_config]

      assert Keyword.get(opts, :tools) ==
               DispatchSurface.standard_tools() ++ ["mcp__code-review-graph"]
    end

    test "is a no-op when no resolved profile is present (test doubles, pre-resolve)" do
      assert DispatchSurface.minimal_default(@workspace, collector: self()) == []
    end

    test "is a no-op when the profile does not advertise the economy opts (non-Claude)" do
      bare = %Profile{
        id: :other,
        command: "other",
        build_args: fn _p, _o -> [] end,
        parse: fn _o -> %{} end,
        supported_opts: [:max_budget_usd]
      }

      assert DispatchSurface.minimal_default(@workspace, profile: bare) == []
    end

    test "is a no-op when there is no workspace (workspaceless loop)" do
      {:ok, profile} = Registry.fetch(:claude)
      assert DispatchSurface.minimal_default(nil, profile: profile) == []
    end
  end

  describe "end-to-end: the surface restricts the Claude argv (the acc)" do
    test "a dispatch carries ONLY the injected server + needed edit/shell tools" do
      {:ok, profile} = Registry.fetch(:claude)
      surface = DispatchSurface.minimal_default(@workspace, profile: profile)

      args = Claude.build_args("fix predicates", surface)

      # The injected orientation/graph server is exposed, scoped to kazi's config.
      assert "--strict-mcp-config" in args
      assert "--mcp-config" in args
      assert @injected_config in args

      # The needed edit/shell tools (plus the injected server's tools) are present.
      assert "--tools" in args

      for tool <- DispatchSurface.standard_tools() ++ ["mcp__code-review-graph"] do
        assert tool in args, "expected #{tool} in the --tools surface"
      end
    end

    test "an IRRELEVANT ambient MCP server's schemas are ABSENT from the prompt" do
      {:ok, profile} = Registry.fetch(:claude)
      surface = DispatchSurface.minimal_default(@workspace, profile: profile)

      args = Claude.build_args("fix predicates", surface)

      # An operator's globally-configured ambient server is NOT in --mcp-config,
      # and `--strict-mcp-config` makes the inner harness ignore it entirely — so
      # its config path never reaches the argv and its schemas never reach the
      # prompt.
      ambient_config = "ambient/.mcp.json"
      refute ambient_config in args
      refute "mcp__some-ambient-server" in args
      # The exclusion is enforced by --strict-mcp-config, not by listing ambient.
      assert "--strict-mcp-config" in args
    end

    test "the default surface is never empty — the --tools list always carries the floor" do
      {:ok, profile} = Registry.fetch(:claude)
      surface = DispatchSurface.minimal_default(@workspace, profile: profile)
      args = Claude.build_args("fix predicates", surface)

      # Locate the --tools window and confirm it is non-empty.
      tools_idx = Enum.find_index(args, &(&1 == "--tools"))
      assert tools_idx != nil
      assert Enum.at(args, tools_idx + 1) == "Read"
    end
  end
end
