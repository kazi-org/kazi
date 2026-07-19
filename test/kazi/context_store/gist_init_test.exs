defmodule Kazi.ContextStore.GistInitTest do
  @moduledoc """
  Tier-2 tests for `Kazi.ContextStore.GistInit` (T35.8, ADR-0045 §8): the
  project-local setup behind `kazi init --with-gist`.

  `doctor/1` is exercised against the SAME file-backed fake binary the GistCLI
  tests use (`test/support/fake_gist.sh`), so the verify step runs hermetically —
  no real `gist`, no network. The file writers are pure IO under a tmp dir; the
  load-bearing guarantee under test is that every write lands PROJECT-LOCAL and is
  idempotent + additive.
  """
  use ExUnit.Case, async: true

  alias Kazi.ContextStore.GistInit

  @fake Path.expand("../../support/fake_gist.sh", __DIR__)

  describe "doctor/1" do
    test "returns {:ok, output} when `gist doctor` runs and exits 0" do
      assert {:ok, out} = GistInit.doctor(gist_bin: @fake)
      assert out =~ "Gist Doctor"
    end

    test "returns {:error, :gist_not_available} when the binary is absent (a name)" do
      assert {:error, :gist_not_available} =
               GistInit.doctor(gist_bin: "kazi-definitely-not-a-real-binary-xyz")
    end

    test "returns {:error, :gist_not_available} when the binary is absent (a path)" do
      assert {:error, :gist_not_available} = GistInit.doctor(gist_bin: "/no/such/dir/gist")
    end
  end

  describe "write_context_toml/1" do
    @describetag :tmp_dir

    test "creates .kazi/context.toml naming the gist provider", %{tmp_dir: dir} do
      assert {:ok, :created, path} = GistInit.write_context_toml(dir)
      assert path == Path.join([dir, ".kazi", "context.toml"])

      assert {:ok, decoded} = Toml.decode(File.read!(path))
      assert decoded["context_store"]["provider"] == "gist"
      # No DSN is written by default — the env var is recommended instead.
      refute Map.has_key?(decoded["context_store"], "dsn")
      assert File.read!(path) =~ "KAZI_GIST_DSN"
    end

    test "is idempotent — a second run on a gist file is :present", %{tmp_dir: dir} do
      assert {:ok, :created, path} = GistInit.write_context_toml(dir)
      before = File.read!(path)

      assert {:ok, :present, ^path} = GistInit.write_context_toml(dir)
      assert File.read!(path) == before
    end

    test "preserves an existing dsn when rewriting a non-gist file", %{tmp_dir: dir} do
      path = Path.join([dir, ".kazi", "context.toml"])
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      [context_store]
      provider = "other"
      dsn = "postgres://u:p@h:5432/db"
      """)

      assert {:ok, :updated, ^path} = GistInit.write_context_toml(dir)
      assert {:ok, decoded} = Toml.decode(File.read!(path))
      assert decoded["context_store"]["provider"] == "gist"
      assert decoded["context_store"]["dsn"] == "postgres://u:p@h:5432/db"
    end

    test "an unparseable existing file is a hard error, not a clobber", %{tmp_dir: dir} do
      path = Path.join([dir, ".kazi", "context.toml"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "this is = = not [ valid toml")

      assert {:error, {:malformed_context_toml, ^path}} = GistInit.write_context_toml(dir)
      # The bad file is left exactly as found.
      assert File.read!(path) == "this is = = not [ valid toml"
    end
  end

  describe "ensure_mcp/1" do
    @describetag :tmp_dir

    test "creates .mcp.json with the gist serve server entry", %{tmp_dir: dir} do
      assert {:ok, :created, path} = GistInit.ensure_mcp(dir)
      assert path == Path.join(dir, ".mcp.json")

      assert {:ok, config} = Jason.decode(File.read!(path))
      assert config["mcpServers"]["gist"] == %{"command" => "gist", "args" => ["serve"]}
    end

    test "is idempotent — a second run is :present with identical bytes", %{tmp_dir: dir} do
      assert {:ok, :created, path} = GistInit.ensure_mcp(dir)
      before = File.read!(path)

      assert {:ok, :present, ^path} = GistInit.ensure_mcp(dir)
      assert File.read!(path) == before
    end

    test "merges additively — preserves servers already declared", %{tmp_dir: dir} do
      path = Path.join(dir, ".mcp.json")

      File.write!(
        path,
        Jason.encode!(%{"mcpServers" => %{"kazi" => %{"command" => "kazi", "args" => ["mcp"]}}})
      )

      assert {:ok, :merged, ^path} = GistInit.ensure_mcp(dir)
      assert {:ok, config} = Jason.decode(File.read!(path))
      assert config["mcpServers"]["kazi"] == %{"command" => "kazi", "args" => ["mcp"]}
      assert config["mcpServers"]["gist"] == %{"command" => "gist", "args" => ["serve"]}
    end

    test "an unparseable existing .mcp.json is a hard error, not a clobber", %{tmp_dir: dir} do
      path = Path.join(dir, ".mcp.json")
      File.write!(path, "{ not json")

      assert {:error, {:invalid_mcp_json, ^path, _reason}} = GistInit.ensure_mcp(dir)
      assert File.read!(path) == "{ not json"
    end
  end
end
