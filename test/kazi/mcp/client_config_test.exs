defmodule Kazi.MCP.ClientConfigTest do
  @moduledoc """
  T33.3 (ADR-0044): the canonical kazi MCP **client** config is the BINARY verb
  `{ "command": "kazi", "args": ["mcp"] }`, and it is emitted/documented the same
  way EVERYWHERE.

  Two tiers:

    * the config source of truth — `Kazi.MCP.ClientConfig` renders the binary-verb
      entry and merges it additively into a repo's `.mcp.json`;
    * the "config everywhere" coherence guard — the canonical inline snippet
      appears verbatim in the generated SKILL.md, `AGENTS.md`, and `README.md`, and
      none of those surfaces emit the old `mix kazi.mcp` JSON-CLI form as the
      canonical client config.
  """
  use ExUnit.Case, async: true

  alias Kazi.MCP.ClientConfig

  @tmp_dir Path.join(System.tmp_dir!(), "kazi-client-config-test")

  setup do
    dir = Path.join(@tmp_dir, "case-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "the canonical config (source of truth)" do
    test "server_entry is the installed BINARY verb, not the mix shell-out" do
      assert ClientConfig.server_entry() == %{"command" => "kazi", "args" => ["mcp"]}
      assert ClientConfig.server_name() == "kazi"
    end

    test "config nests the entry under mcpServers.kazi" do
      assert ClientConfig.config() == %{
               "mcpServers" => %{"kazi" => %{"command" => "kazi", "args" => ["mcp"]}}
             }
    end

    test "json round-trips to the config map" do
      assert {:ok, decoded} = Jason.decode(ClientConfig.json())
      assert decoded == ClientConfig.config()
    end

    test "inline is the exact snippet the docs embed" do
      assert ClientConfig.inline() ==
               ~s({ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } })
    end
  end

  describe "ensure_in_dir/1 (additive, idempotent)" do
    test "creates .mcp.json with the canonical config when none exists", %{dir: dir} do
      assert {:ok, :created, path} = ClientConfig.ensure_in_dir(dir)
      assert path == Path.join(dir, ".mcp.json")
      assert {:ok, config} = Jason.decode(File.read!(path))
      assert config == ClientConfig.config()
    end

    test "a second call is a no-op (present, byte-identical)", %{dir: dir} do
      assert {:ok, :created, path} = ClientConfig.ensure_in_dir(dir)
      first = File.read!(path)

      assert {:ok, :present, ^path} = ClientConfig.ensure_in_dir(dir)
      assert File.read!(path) == first
    end

    test "merges additively, preserving other servers and top-level keys", %{dir: dir} do
      path = Path.join(dir, ".mcp.json")

      File.write!(
        path,
        Jason.encode!(%{
          "mcpServers" => %{"other" => %{"command" => "other-server"}},
          "someTopLevelKey" => true
        })
      )

      assert {:ok, :merged, ^path} = ClientConfig.ensure_in_dir(dir)
      assert {:ok, config} = Jason.decode(File.read!(path))

      assert config["mcpServers"]["kazi"] == ClientConfig.server_entry()
      assert config["mcpServers"]["other"] == %{"command" => "other-server"}
      assert config["someTopLevelKey"] == true
    end

    test "refuses to clobber a malformed .mcp.json", %{dir: dir} do
      File.write!(Path.join(dir, ".mcp.json"), "{ not json")
      assert {:error, {:invalid_mcp_json, _path, _reason}} = ClientConfig.ensure_in_dir(dir)
    end
  end

  describe "the config is canonical EVERYWHERE (coherence guard)" do
    @canonical_inline ~s({ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } })

    # The old JSON-CLI form is fine as the DEVELOPMENT entry point, but must never
    # be presented as the canonical CLIENT config — these markers would mean a
    # surface still tells a harness to wire `mix kazi.mcp` as its server command.
    @json_cli_marker ~s("command": "mix", "args": ["kazi.mcp"])

    test "the generated SKILL.md embeds the canonical config and leads with MCP" do
      skill = Kazi.Teach.InstallSkill.skill_md()
      assert String.contains?(skill, @canonical_inline)
      refute String.contains?(skill, @json_cli_marker)
      assert skill =~ ~r/MCP first/i
    end

    test "AGENTS.md embeds the canonical config and leads with MCP" do
      agents = File.read!("AGENTS.md")
      assert String.contains?(agents, @canonical_inline)
      refute String.contains?(agents, @json_cli_marker)
      assert agents =~ ~r/MCP first/i
    end

    test "README.md embeds the canonical config" do
      readme = File.read!("README.md")
      assert String.contains?(readme, @canonical_inline)
      refute String.contains?(readme, @json_cli_marker)
    end

    test "the inline snippet equals ClientConfig.inline/0 (single source of truth)" do
      assert @canonical_inline == ClientConfig.inline()
    end
  end
end
