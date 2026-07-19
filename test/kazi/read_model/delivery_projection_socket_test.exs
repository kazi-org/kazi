defmodule Kazi.ReadModel.DeliveryProjectionSocketTest do
  @moduledoc """
  T67.2 daemon-write acceptance (ADR-0079 §3 / ADR-0068, the T52.5 socket seam):
  the delivery projection's writes must cross the daemon control socket in
  daemon-alive mode, not take the direct path. A test-harness "daemon" binds the
  socket the `Kazi.ReadModel.Writer` presence probe resolves to, applies each
  `write` op through the real T52.3 server against the shared sandbox repo, and
  counts the op kinds it serves so the test can prove the projection's inserts
  went through the wire.
  """
  use ExUnit.Case, async: false

  alias Kazi.Daemon.{Probe, Supervisor}
  alias Kazi.ReadModel.{DeliveryEvent, DeliveryProjection}
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    id = System.unique_integer([:positive])
    state_dir = "/tmp/kazi_delivery_sock_#{id}"
    prev = System.get_env("KAZI_STATE_DIR")
    System.put_env("KAZI_STATE_DIR", state_dir)

    sock_path = Supervisor.default_sock_path()
    File.mkdir_p!(Path.dirname(sock_path))

    prev_sock = Application.get_env(:kazi, :read_model_writer_sock)
    Application.put_env(:kazi, :read_model_writer_sock, sock_path)

    {:ok, counter} = Agent.start_link(fn -> [] end)
    listen_socket = start_harness!(sock_path, counter)
    wait_until(fn -> Probe.probe(sock_path) == :alive end)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
      File.rm(sock_path)
      File.rm_rf(state_dir)

      if prev_sock,
        do: Application.put_env(:kazi, :read_model_writer_sock, prev_sock),
        else: Application.delete_env(:kazi, :read_model_writer_sock)

      if prev,
        do: System.put_env("KAZI_STATE_DIR", prev),
        else: System.delete_env("KAZI_STATE_DIR")
    end)

    %{ops: counter}
  end

  test "the projection's rows are written through the daemon socket", %{ops: ops} do
    dir = init_repo()

    commit(
      dir,
      "docs/plans/E42.md",
      "- [x] T42.1 socketed task  Done: 2026-07-18 (PR #420)",
      "docs(plan): tick T42.1",
      session: "session_sock"
    )

    assert {:ok, summary} = DeliveryProjection.project(dir, repo_slug: "acme/widget")
    assert summary.task_ticks == 1
    assert summary.pr_merges == 1

    # The socket, not the direct path, carried the writes.
    assert "insert" in served_kinds(ops)

    # And the daemon actually persisted the rows.
    row = Repo.get_by(DeliveryEvent, kind: "task_tick", task_id: "T42.1")
    assert row.pr_number == 420
    assert row.trailer_session_id == "session_sock"
  end

  # --- git fixture -----------------------------------------------------------

  defp init_repo do
    dir = Path.join(System.tmp_dir!(), "kazi_delivery_gr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs/plans"))
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "fixture@example.test"])
    git!(dir, ["config", "user.name", "fixture"])
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp commit(dir, file, added_lines, subject, opts \\ []) do
    path = Path.join(dir, file)

    existing =
      case File.read(path) do
        {:ok, content} -> content
        _ -> ""
      end

    File.write!(path, [existing, added_lines, "\n"])
    git!(dir, ["add", "-A"])

    trailer =
      case opts[:session] do
        nil -> []
        token -> ["-m", "Claude-Session: https://claude.ai/code/#{token}"]
      end

    git!(dir, ["commit", "-q", "-m", subject] ++ trailer)
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  # --- harness daemon (T52.5) ------------------------------------------------

  defp start_harness!(sock_path, counter) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:packet, :line},
        {:active, false},
        {:backlog, 16},
        {:buffer, Probe.socket_buffer()},
        {:ifaddr, {:local, sock_path}}
      ])

    spawn_link(fn -> accept_loop(listen_socket, counter) end)
    listen_socket
  end

  defp accept_loop(listen_socket, counter) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, counter) end)
        accept_loop(listen_socket, counter)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, counter) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 2_000),
         {:ok, request} <- Jason.decode(line) do
      record_op(counter, request)
      reply = Kazi.Daemon.Control.handle(request, [])
      _ = :gen_tcp.send(socket, Jason.encode!(reply) <> "\n")
    end

    :gen_tcp.close(socket)
  end

  defp record_op(counter, %{"op" => "write", "batch" => batch}) do
    Agent.update(counter, &(&1 ++ Enum.map(batch, fn e -> Map.get(e, "kind") end)))
  end

  defp record_op(_counter, _request), do: :ok

  defp served_kinds(counter), do: Agent.get(counter, & &1)

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition never became true")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
