defmodule KaziWeb.CoordinationSourceSelectTest do
  use ExUnit.Case, async: false

  alias Kazi.TestSupport.FakeDaemonSocket
  alias KaziWeb.CoordinationSource

  setup do
    prev_source = Application.get_env(:kazi, :lease_map_source)
    prev_opts = Application.get_env(:kazi, :coordination_opts)
    Application.delete_env(:kazi, :coordination_opts)
    prev_sock = Application.get_env(:kazi, :lease_map_daemon_sock)
    Application.delete_env(:kazi, :lease_map_source)

    on_exit(fn ->
      restore(:coordination_opts, prev_opts)
      restore(:lease_map_source, prev_source)
      restore(:lease_map_daemon_sock, prev_sock)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:kazi, key)
  defp restore(key, value), do: Application.put_env(:kazi, key, value)

  test "daemon availability does not select a messaging roster" do
    sock = FakeDaemonSocket.start!()
    Application.put_env(:kazi, :lease_map_daemon_sock, sock)

    assert CoordinationSource.select() == KaziWeb.CoordinationSource.Native
  end

  test "configured coordination selects transport" do
    Application.put_env(:kazi, :coordination_opts, [])
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
