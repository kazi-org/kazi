defmodule KaziWeb.CoordinationSourceSelectTest do
  @moduledoc """
  T55.3 (ADR-0073 §4): the dashboard's source choice is decided, not hardcoded.

  `KaziWeb.CoordinationSource.select/0` must pick the transport-backed source
  when a daemon control socket probes `:alive` (via the same `Kazi.Daemon.Probe`
  seam the CLI's daemon verbs use), fall back to the native source when no
  daemon is reachable, and always yield to an explicit `:lease_map_source`
  override (the pre-existing ADR-0011 §3 injection seam).

  Hermetic: the "daemon" is `Kazi.TestSupport.FakeDaemonSocket`, a bare Unix
  socket listener — no real daemon, no NATS.
  """
  use ExUnit.Case, async: false

  alias Kazi.TestSupport.FakeDaemonSocket
  alias KaziWeb.CoordinationSource

  setup do
    prev_source = Application.get_env(:kazi, :lease_map_source)
    prev_sock = Application.get_env(:kazi, :lease_map_daemon_sock)
    Application.delete_env(:kazi, :lease_map_source)

    on_exit(fn ->
      restore(:lease_map_source, prev_source)
      restore(:lease_map_daemon_sock, prev_sock)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kazi, key)
  defp restore(key, value), do: Application.put_env(:kazi, key, value)

  test "defaults to the transport-backed source when a daemon socket is alive" do
    sock = FakeDaemonSocket.start!()
    Application.put_env(:kazi, :lease_map_daemon_sock, sock)

    assert CoordinationSource.select() == KaziWeb.CoordinationSource.Transport
  end

  test "falls back to the native source when no daemon socket exists" do
    Application.put_env(
      :kazi,
      :lease_map_daemon_sock,
      Path.join(System.tmp_dir!(), "kazi-t553-absent-#{System.unique_integer([:positive])}.sock")
    )

    assert CoordinationSource.select() == KaziWeb.CoordinationSource.Native
  end

  test "falls back to the native source on a stale (dead) socket file" do
    # A leftover file no listener owns: probe classifies :dead, select must
    # treat it exactly like no daemon.
    path = Path.join(System.tmp_dir!(), "kazi-t553-dead-#{System.unique_integer([:positive])}")
    File.touch!(path)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:kazi, :lease_map_daemon_sock, path)

    assert CoordinationSource.select() == KaziWeb.CoordinationSource.Native
  end

  test "an explicit :lease_map_source override always wins, daemon or not" do
    sock = FakeDaemonSocket.start!()
    Application.put_env(:kazi, :lease_map_daemon_sock, sock)
    Application.put_env(:kazi, :lease_map_source, KaziWeb.CoordinationFixtureSource)

    assert CoordinationSource.select() == KaziWeb.CoordinationFixtureSource
  end
end
