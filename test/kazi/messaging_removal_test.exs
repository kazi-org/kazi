defmodule Kazi.MessagingRemovalTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  test "CLI rejects removed messaging commands and transport flags" do
    for argv <- [["bus", "who"], ["install-hooks"], ["daemon", "start", "--nats-port", "4223"]] do
      assert {:error, _} = Kazi.CLI.parse(argv)
    end

    help = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end) |> Jason.decode!()
    commands = Enum.map(help["commands"], & &1["name"])
    refute "bus" in commands
    refute "install-hooks" in commands
    assert "daemon" in commands
  end

  test "bus schema and MCP tools are removed" do
    schemas = Kazi.CLI.Schema.all()
    refute Map.has_key?(schemas.schemas, "bus")
    refute Enum.any?(Kazi.MCP.Server.tools(), &String.starts_with?(&1["name"], "kazi_bus_"))

    response =
      Kazi.MCP.Server.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "kazi_bus_post",
          "arguments" => %{"kind" => "fact", "text" => "hello"}
        }
      })

    assert response["error"]["code"] == -32601
  end

  test "generated teaching directs communication to Ajent" do
    recipes = Kazi.Teach.InstallSkill.recipes_md()
    assert recipes =~ "ajent setup"
    refute recipes =~ "kazi bus"
    refute recipes =~ "kazi_bus_"
    refute Map.has_key?(Kazi.Plugin.Manifest.manifest(), "hooks")
  end
end
