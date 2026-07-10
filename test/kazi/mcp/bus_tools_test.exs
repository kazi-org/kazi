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
      assert "kazi_bus_who" in names
      assert "kazi_bus_tell" in names
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
      oversize = String.duplicate("x", 1025)
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
