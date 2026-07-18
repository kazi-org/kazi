defmodule Kazi.ReadModel.WriterSocketTest do
  @moduledoc """
  T52.5 (ADR-0068 decision 1): the socket round-trip acceptance. Unlike
  `Kazi.ReadModel.WriterTest` (which mocks the `:remote` closure), this drives a
  REAL Unix-domain control socket end to end: a test-harness "daemon" binds the
  socket the `Kazi.ReadModel.Writer` presence probe resolves to, applies each
  `write` op through the T52.3 server (`Kazi.Daemon.Write`) against the shared
  sandbox `Kazi.Repo`, and counts the ops it serves so a test can prove a write
  actually crossed the wire (the alive branch was taken, not the direct one).

  `async: false` + shared-mode sandbox: the harness serves each connection in a
  spawned process, so the read-model connection must be shared across processes.
  A "second reader process" reading the finished row is therefore a genuinely
  separate process observing the daemon's write, even though the sandbox shares
  one underlying connection (the production separation is one writer / many
  readers on distinct SQLite connections; the sandbox collapses them but the
  cross-process visibility contract is what this pins).
  """
  use ExUnit.Case, async: false

  alias Kazi.Daemon.{Probe, Supervisor}
  alias Kazi.ReadModel.{ProposedGoal, Run, RunRegistry}
  alias Kazi.ReadModel.Writer
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Point the default sock path (the one RunRegistry's Writer calls resolve,
    # since it passes no sock_path) at a throwaway tmp state dir -- never the
    # real ~/.kazi daemon, never the running daemon's socket.
    id = System.unique_integer([:positive])
    state_dir = "/tmp/kazi_wsock_#{id}"
    prev = System.get_env("KAZI_STATE_DIR")
    System.put_env("KAZI_STATE_DIR", state_dir)

    sock_path = Supervisor.default_sock_path()
    File.mkdir_p!(Path.dirname(sock_path))

    # The test env points the Writer's default sock at a never-existing socket
    # (config/test.exs); override it to THIS harness so RunRegistry's calls
    # (which pass no sock_path) route here.
    prev_sock = Application.get_env(:kazi, :read_model_writer_sock)
    Application.put_env(:kazi, :read_model_writer_sock, sock_path)

    {:ok, counter} = Agent.start_link(fn -> [] end)
    listen_socket = start_harness!(sock_path, counter)

    # The probe the Writer uses must see the harness as alive before we route.
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

    %{sock_path: sock_path, ops: counter}
  end

  # A minimal test-harness daemon: bind the control socket, and answer each
  # `write` op through the real T52.3 server against the shared sandbox repo,
  # recording every op kind so a test can assert the socket carried the write.
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
    kinds = Enum.map(batch, &Map.get(&1, "kind"))
    Agent.update(counter, &(&1 ++ kinds))
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

  describe "run-registry through the socket (#1019 blind-run class)" do
    test "start then finish persist through the socket; a second reader sees the finished row",
         %{ops: ops} do
      run_id = "run-#{System.unique_integer([:positive])}"

      assert {:ok, %Run{} = started} =
               RunRegistry.start(%{
                 run_id: run_id,
                 pid: "4242",
                 workspace: "/tmp/ws",
                 goal_ref: "goal-socket"
               })

      assert started.run_id == run_id
      assert started.status == "running"

      assert {:ok, %Run{} = finished} = RunRegistry.finish(run_id, "converged")
      assert finished.status == "converged"
      assert finished.finished_at

      # The socket, not the direct path, carried BOTH writes: an insert (start)
      # then an update_all (finish).
      assert "insert" in served_kinds(ops)
      assert "update_all" in served_kinds(ops)

      # A separate process reads the row the daemon wrote and sees the terminal
      # status + stamped finish time -- the write reached the single writer.
      reader =
        Task.async(fn -> RunRegistry.get(run_id) end)

      row = Task.await(reader)
      assert %Run{status: "converged"} = row
      assert row.finished_at
    end
  end

  describe "upsert conflict handling through the socket" do
    test "an on_conflict replace still replaces on the conflict target", %{sock_path: sock} do
      proposal_ref = "prop-#{System.unique_integer([:positive])}"

      # authoring.ex's exact upsert opts.
      opts = [
        on_conflict:
          {:replace,
           [:idea, :goal_id, :status, :goal, :session_name, :roadmap_ref, :discovery, :updated_at]},
        conflict_target: :proposal_ref
      ]

      base = %{proposal_ref: proposal_ref, goal_id: "g1", status: "proposed", goal: %{"a" => 1}}

      assert {:ok, _} =
               %ProposedGoal{}
               |> ProposedGoal.changeset(Map.put(base, :idea, "first idea"))
               |> Writer.insert(opts, sock_path: sock)

      assert {:ok, replaced} =
               %ProposedGoal{}
               |> ProposedGoal.changeset(Map.put(base, :idea, "second idea"))
               |> Writer.insert(opts, sock_path: sock)

      # The conflict-target upsert replaced in place (one row), and the returned
      # row -- re-read by its conflict target -- reflects the replacement.
      assert replaced.idea == "second idea"
      assert Repo.aggregate(ProposedGoal, :count, :id) == 1
      assert Repo.get_by(ProposedGoal, proposal_ref: proposal_ref).idea == "second idea"
    end
  end

  describe "raw FTS statements through the socket" do
    test "an FTS insert round-trips and a delete removes it", %{sock_path: sock} do
      root = "/tmp/ws-#{System.unique_integer([:positive])}"
      path = "docs/note.md"

      assert :ok =
               Writer.query!(
                 "INSERT INTO memory_chunks_fts (workspace_root, path, heading, line_start, line_end, body) VALUES (?, ?, ?, ?, ?, ?)",
                 [root, path, "H", 1, 2, "a body to match"],
                 sock_path: sock
               )

      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*) FROM memory_chunks_fts WHERE workspace_root = ?", [
                 root
               ])

      assert :ok =
               Writer.query!(
                 "DELETE FROM memory_chunks_fts WHERE workspace_root = ? AND path = ?",
                 [root, path],
                 sock_path: sock
               )

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM memory_chunks_fts WHERE workspace_root = ?", [
                 root
               ])
    end
  end
end
