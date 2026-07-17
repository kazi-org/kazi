defmodule Kazi.MCP.BusToolsTest do
  @moduledoc """
  T51.2 follow-up (ADR-0067): the `kazi_bus_post`/`kazi_bus_read`/`kazi_bus_who`/
  `kazi_bus_tell` MCP tool surface. Untagged (no NATS needed): tools/list
  self-description, missing-argument errors, and the no-daemon error path
  (mirrors `Kazi.Bus.MvpTest`'s no-daemon coverage).
  """
  use ExUnit.Case, async: true

  alias Kazi.MCP.Server

  describe "tools/list — the four bus tools" do
    test "each is self-describing with a name, description, and inputSchema" do
      names = Server.tools() |> Enum.map(& &1["name"])

      assert "kazi_bus_post" in names
      assert "kazi_bus_read" in names
      assert "kazi_bus_watch" in names
      assert "kazi_bus_who" in names
      assert "kazi_bus_tell" in names
    end

    test "kazi_bus_read declares the peek argument; kazi_bus_watch the timeout" do
      by_name = Map.new(Server.tools(), &{&1["name"], &1})

      assert %{"type" => "boolean"} =
               by_name["kazi_bus_read"]["inputSchema"]["properties"]["peek"]

      assert %{"type" => "number"} =
               by_name["kazi_bus_watch"]["inputSchema"]["properties"]["timeout"]
    end

    test "kazi_bus_read and kazi_bus_watch declare the full escape and teach the digest (ADR-0072)" do
      by_name = Map.new(Server.tools(), &{&1["name"], &1})

      for tool <- ["kazi_bus_read", "kazi_bus_watch"] do
        assert %{"type" => "boolean"} = by_name[tool]["inputSchema"]["properties"]["full"],
               "#{tool} must declare a boolean `full` argument"

        assert by_name[tool]["description"] =~ "digest",
               "#{tool}'s description must teach the digest default"
      end
    end

    test "kazi_bus_watch declares the since anchor argument (T54.9, #1097)" do
      by_name = Map.new(Server.tools(), &{&1["name"], &1})

      assert %{"type" => "string"} =
               by_name["kazi_bus_watch"]["inputSchema"]["properties"]["since"]

      assert by_name["kazi_bus_watch"]["description"] =~ "since"
    end

    test "post/tell declare their required arguments" do
      by_name = Map.new(Server.tools(), &{&1["name"], &1})

      assert by_name["kazi_bus_post"]["inputSchema"]["required"] == ["kind", "text"]
      assert by_name["kazi_bus_tell"]["inputSchema"]["required"] == ["session", "text"]
    end
  end

  describe "tools/call — missing required arguments" do
    test "kazi_bus_post without kind/text is an invalid-params error" do
      response = call("kazi_bus_post", %{})

      assert %{"error" => %{"code" => -32_602}} = response
    end

    test "kazi_bus_tell without session/text is an invalid-params error" do
      response = call("kazi_bus_tell", %{"session" => "someone"})

      assert %{"error" => %{"code" => -32_602}} = response
    end
  end

  describe "tools/call — no daemon running" do
    setup do
      %{
        opts: [
          sock_path: "/tmp/kazi_mcp_bus_test_missing_#{System.unique_integer([:positive])}.sock"
        ]
      }
    end

    test "kazi_bus_post surfaces a structured no_daemon tool error", %{opts: opts} do
      response = call("kazi_bus_post", %{"kind" => "note", "text" => "hi"}, opts)

      assert %{"result" => %{"isError" => true, "structuredContent" => content}} = response
      assert content["reason"] == "no_daemon"
    end

    test "kazi_bus_read surfaces a structured no_daemon tool error", %{opts: opts} do
      response = call("kazi_bus_read", %{}, opts)

      assert %{"result" => %{"isError" => true, "structuredContent" => content}} = response
      assert content["reason"] == "no_daemon"
    end

    test "kazi_bus_read with peek: true surfaces a structured no_daemon tool error", %{
      opts: opts
    } do
      response = call("kazi_bus_read", %{"peek" => true}, opts)

      assert %{"result" => %{"isError" => true, "structuredContent" => content}} = response
      assert content["reason"] == "no_daemon"
    end

    test "kazi_bus_watch surfaces a structured no_daemon tool error", %{opts: opts} do
      response = call("kazi_bus_watch", %{"timeout" => 1}, opts)

      assert %{"result" => %{"isError" => true, "structuredContent" => content}} = response
      assert content["reason"] == "no_daemon"
    end

    test "kazi_bus_who surfaces a structured no_daemon tool error", %{opts: opts} do
      response = call("kazi_bus_who", %{}, opts)

      assert %{"result" => %{"isError" => true, "structuredContent" => content}} = response
      assert content["reason"] == "no_daemon"
    end

    test "kazi_bus_tell surfaces a structured no_daemon tool error", %{opts: opts} do
      response = call("kazi_bus_tell", %{"session" => "someone", "text" => "hi"}, opts)

      assert %{"result" => %{"isError" => true, "structuredContent" => content}} = response
      assert content["reason"] == "no_daemon"
    end
  end

  describe "tools/call — oversize text is rejected client-side" do
    test "kazi_bus_post reports text_too_large before touching any daemon" do
      oversize = String.duplicate("x", 65_537)
      response = call("kazi_bus_post", %{"kind" => "note", "text" => oversize})

      assert %{"result" => %{"isError" => true, "structuredContent" => content}} = response
      assert content["reason"] == "text_too_large"
    end
  end

  defp call(name, arguments, opts \\ []) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }

    Server.handle_request(request, opts)
  end
end
