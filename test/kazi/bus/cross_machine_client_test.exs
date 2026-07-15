defmodule Kazi.Bus.CrossMachineClientTest do
  @moduledoc """
  Issue #1101: the CLI bus client must dial the daemon's CONFIGURED nats host
  (the connect-mode remote, not a hardcoded 127.0.0.1) and present the shared
  auth token, so a cross-machine `--nats-host [--nats-token]` bus works from the
  CLI without an SSH tunnel and without an Authorization Violation.

  Issue #1102: `bus who` presence entries carry a `machine` field so a shared
  cross-machine roster is attributable per machine.

  These are UNTAGGED (no live nats): the connect-mode `Kazi.Daemon.Nats` init
  only stores config, the control ping handler is pure over it, and
  `discovered_connect_opts/2` is a pure function over the handshake map.
  """
  use ExUnit.Case, async: true

  alias Kazi.Bus
  alias Kazi.Daemon.{Control, Nats}

  describe "discovered_connect_opts/2 (issue #1101 — the client half)" do
    test "dials the daemon-advertised remote host with the shared token" do
      pong = %{"nats_host" => "10.0.0.5", "nats_token" => "s3cret"}

      assert Bus.discovered_connect_opts(pong, 4223) ==
               %{host: "10.0.0.5", port: 4223, auth_token: "s3cret"}
    end

    test "omits auth_token when the bus is unauthenticated" do
      pong = %{"nats_host" => "10.0.0.5"}
      assert Bus.discovered_connect_opts(pong, 4223) == %{host: "10.0.0.5", port: 4223}
    end

    test "falls back to 127.0.0.1 when an older daemon omits nats_host (back-compat)" do
      assert Bus.discovered_connect_opts(%{}, 4223) == %{host: "127.0.0.1", port: 4223}
    end

    test "reads KAZI_NATS_TOKEN when the handshake carries no token" do
      System.put_env("KAZI_NATS_TOKEN", "from-env")
      on_exit(fn -> System.delete_env("KAZI_NATS_TOKEN") end)

      assert Bus.discovered_connect_opts(%{"nats_host" => "h"}, 4223) ==
               %{host: "h", port: 4223, auth_token: "from-env"}
    end

    test "the handshake token wins over KAZI_NATS_TOKEN" do
      System.put_env("KAZI_NATS_TOKEN", "env-token")
      on_exit(fn -> System.delete_env("KAZI_NATS_TOKEN") end)

      assert %{auth_token: "handshake-token"} =
               Bus.discovered_connect_opts(
                 %{"nats_host" => "h", "nats_token" => "handshake-token"},
                 4223
               )
    end
  end

  describe "daemon control ping surfaces nats host + token (issue #1101 — the daemon half)" do
    test "a connect-mode Nats advertises its remote host and token through the ping" do
      name = :"nats_ping_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Nats.start_link(name: name, nats_host: "10.0.0.5", port: 4223, nats_token: "s3cret")

      assert Nats.host(name) == "10.0.0.5"
      assert Nats.token(name) == "s3cret"
      assert Nats.port(name) == 4223

      pong = Control.handle(%{"op" => "ping"}, nats_name: name)
      assert pong["nats_host"] == "10.0.0.5"
      assert pong["nats_token"] == "s3cret"
      assert pong["nats_port"] == 4223
    end

    test "an unauthenticated bus OMITS nats_token from the ping (clean handshake)" do
      name = :"nats_ping_notoken_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Nats.start_link(name: name, nats_host: "10.0.0.5", port: 4223)

      pong = Control.handle(%{"op" => "ping"}, nats_name: name)
      assert pong["nats_host"] == "10.0.0.5"
      refute Map.has_key?(pong, "nats_token")
    end

    test "no nats process (nil name) leaves the ping's nats fields nil, never crashing" do
      pong = Control.handle(%{"op" => "ping"}, nats_name: nil)
      assert pong["ok"] == true
      assert pong["nats_host"] == nil
      assert pong["nats_port"] == nil
      refute Map.has_key?(pong, "nats_token")
    end
  end
end
