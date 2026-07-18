defmodule Kazi.Plugin.ManifestTest do
  use ExUnit.Case, async: true

  alias Kazi.MCP.ClientConfig
  alias Kazi.Plugin.Manifest
  alias Kazi.Teach.InstallHooks
  alias Kazi.Teach.InstallSkill

  @fixed_version "1.246.0"

  describe "manifest/1 -- Claude Code plugin schema" do
    test "validates against the documented plugin.json schema" do
      m = Manifest.manifest(version: @fixed_version)
      assert schema_errors(m) == []
    end

    test "name is the required kebab-case identifier" do
      m = Manifest.manifest(version: @fixed_version)
      assert m["name"] == "kazi"
      assert Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, m["name"])
    end

    test "version is set from the :version option (lockstep with the binary)" do
      assert Manifest.manifest(version: "9.9.9")["version"] == "9.9.9"
    end

    test "version defaults to the running kazi version when unset" do
      expected = to_string(Application.spec(:kazi, :vsn))
      assert Manifest.manifest()["version"] == expected
    end

    test "keywords is an array of strings (a string there is a load error)" do
      assert is_list(Manifest.manifest(version: @fixed_version)["keywords"])
      assert Enum.all?(Manifest.manifest()["keywords"], &is_binary/1)
    end

    test "author is an object carrying a name" do
      author = Manifest.manifest(version: @fixed_version)["author"]
      assert is_map(author)
      assert is_binary(author["name"])
    end
  end

  describe "mcpServers -- matches init --with-mcp" do
    test "the kazi server entry is byte-for-byte ClientConfig's registration" do
      servers = Manifest.manifest(version: @fixed_version)["mcpServers"]

      assert servers == %{ClientConfig.server_name() => ClientConfig.server_entry()}
      assert servers["kazi"] == %{"command" => "kazi", "args" => ["mcp"]}
    end

    test "mcpServers stays equal to init --with-mcp's config source" do
      # ClientConfig.config/0 is what `init --with-mcp` writes into .mcp.json;
      # the plugin's inline block must be the same mcpServers value.
      assert Manifest.mcp_servers() == ClientConfig.config()["mcpServers"]
    end
  end

  describe "hooks -- matches T55.9's implemented events" do
    test "every InstallHooks registration appears with the same command" do
      hooks = Manifest.manifest(version: @fixed_version)["hooks"]

      for {event, command} <- InstallHooks.hook_commands() do
        assert [%{"hooks" => [entry]}] = hooks[event]
        assert entry == %{"type" => "command", "command" => command}
      end
    end

    test "no extra events beyond what install-hooks registers" do
      declared = Manifest.manifest()["hooks"] |> Map.keys() |> Enum.sort()
      implemented = InstallHooks.hook_commands() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert declared == implemented
    end
  end

  describe "bundle/1 -- rendered skill content" do
    test "bundles the manifest plus every InstallSkill doc under skills/kazi/" do
      paths = Manifest.bundle(version: @fixed_version) |> Enum.map(&elem(&1, 0))

      assert ".claude-plugin/plugin.json" in paths

      for {name, _content} <- InstallSkill.docs() do
        assert "skills/kazi/#{name}" in paths
      end
    end

    test "skill file contents are the InstallSkill renderer output verbatim" do
      bundle = Map.new(Manifest.bundle(version: @fixed_version))

      for {name, content} <- InstallSkill.docs() do
        assert bundle["skills/kazi/#{name}"] == content
      end
    end

    test "never bundles LOCAL.md (ADR-0077 decision 3 -- replaced-dir safety)" do
      paths = Manifest.bundle(version: @fixed_version) |> Enum.map(&elem(&1, 0))
      refute Enum.any?(paths, &String.ends_with?(&1, InstallSkill.local_file()))
    end
  end

  describe "determinism (acceptance)" do
    test "same version -> byte-identical manifest JSON" do
      a = Manifest.manifest_json(version: @fixed_version)
      b = Manifest.manifest_json(version: @fixed_version)
      assert a == b
    end

    test "same version -> byte-identical bundle" do
      assert Manifest.bundle(version: @fixed_version) ==
               Manifest.bundle(version: @fixed_version)
    end

    test "manifest JSON is valid, pretty-printed, newline-terminated" do
      json = Manifest.manifest_json(version: @fixed_version)
      assert String.ends_with?(json, "}\n")
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded == Manifest.manifest(version: @fixed_version)
    end
  end

  describe "write/2" do
    test "writes the full bundle and re-writing is a byte-identical no-op" do
      dir = Path.join(System.tmp_dir!(), "kazi-plugin-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, root} = Manifest.write(dir, version: @fixed_version)
      assert root == Path.expand(dir)

      manifest_bytes = File.read!(Path.join(root, ".claude-plugin/plugin.json"))
      assert manifest_bytes == Manifest.manifest_json(version: @fixed_version)

      # SKILL.md is discoverable by the default skills/ scan.
      assert File.exists?(Path.join(root, "skills/kazi/SKILL.md"))
      refute File.exists?(Path.join(root, "skills/kazi/LOCAL.md"))

      # Deterministic re-render over the same version leaves bytes untouched.
      assert {:ok, ^root} = Manifest.write(dir, version: @fixed_version)
      assert File.read!(Path.join(root, ".claude-plugin/plugin.json")) == manifest_bytes
    end
  end

  # A minimal validator for the documented Claude Code plugin manifest schema
  # (the plugins reference): required `name` (kebab-case string), and typed
  # optional fields. Returns a list of human-readable errors ([] == valid).
  defp schema_errors(m) do
    []
    |> check(is_map(m), "manifest must be a JSON object")
    |> check(is_binary(m["name"]), "name is required and must be a string")
    |> check(
      is_binary(m["name"]) and Regex.match?(~r/^[a-z0-9]+(-[a-z0-9]+)*$/, m["name"]),
      "name must be kebab-case with no spaces"
    )
    |> check(string_or_nil(m["version"]), "version must be a string")
    |> check(string_or_nil(m["description"]), "description must be a string")
    |> check(string_or_nil(m["homepage"]), "homepage must be a string")
    |> check(string_or_nil(m["repository"]), "repository must be a string")
    |> check(string_or_nil(m["license"]), "license must be a string")
    |> check(is_nil(m["author"]) or is_map(m["author"]), "author must be an object")
    |> check(
      is_nil(m["keywords"]) or (is_list(m["keywords"]) and Enum.all?(m["keywords"], &is_binary/1)),
      "keywords must be an array of strings"
    )
    |> check(mcp_servers_valid?(m["mcpServers"]), "mcpServers must map names to server configs")
    |> check(hooks_valid?(m["hooks"]), "hooks must map events to hook-entry arrays")
    |> Enum.reverse()
  end

  defp check(errors, true, _msg), do: errors
  defp check(errors, false, msg), do: [msg | errors]

  defp string_or_nil(v), do: is_nil(v) or is_binary(v)

  defp mcp_servers_valid?(nil), do: true

  defp mcp_servers_valid?(servers) when is_map(servers) do
    Enum.all?(servers, fn {name, cfg} ->
      is_binary(name) and is_map(cfg) and is_binary(cfg["command"])
    end)
  end

  defp mcp_servers_valid?(_), do: false

  defp hooks_valid?(nil), do: true

  defp hooks_valid?(hooks) when is_map(hooks) do
    Enum.all?(hooks, fn {event, entries} ->
      is_binary(event) and is_list(entries) and Enum.all?(entries, &hook_entry_valid?/1)
    end)
  end

  defp hooks_valid?(_), do: false

  defp hook_entry_valid?(%{"hooks" => inner}) when is_list(inner) do
    Enum.all?(inner, fn h -> is_map(h) and h["type"] == "command" and is_binary(h["command"]) end)
  end

  defp hook_entry_valid?(_), do: false
end
