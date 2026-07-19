defmodule Kazi.Bus.BoardMachinePathTest do
  @moduledoc """
  T55.4 (ADR-0073 decision point 1): `kazi bus board` against a REAL NATS
  JetStream server.

  `:nats`-tagged (excluded by default; `NATS_URL` required), mirroring
  `Kazi.Bus.DigestMachinePathTest`: each test provisions for itself, passes
  `opts[:conn]` directly, and uses a UNIQUE custom scope so the scoped fact
  subjects (`bus.<scope>.fact.>`) never see another test's traffic.

  Covers the task's acceptance: three facts on one topic render ONE current
  line (the last); the board is cursor-free (two boards agree on the scoped
  facts, and a subsequent `read` still drains every pending message); the
  roster reuses `who`'s presence path; a 60 KiB fact is a stub; and the fact
  section is bounded regardless of topic count.
  """
  use ExUnit.Case, async: false

  alias Kazi.Bus
  alias Kazi.Bus.Digest
  alias Kazi.Bus.Provision
  alias Kazi.MCP.Server

  @moduletag :nats_group

  describe "the board against a real JetStream server" do
    @describetag :nats

    setup do
      {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
      {:ok, conn} = Gnat.start_link(%{host: host, port: port})
      on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
      :ok = Provision.provision(conn)
      %{conn: conn}
    end

    test "three facts on one topic render ONE current line -- the last value", %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]

      assert :ok = Bus.post("fact", "main is red", opts ++ [topic: "ci"])
      assert :ok = Bus.post("fact", "still red", opts ++ [topic: "ci"])
      assert :ok = Bus.post("fact", "main is green", opts ++ [topic: "ci"])

      assert {:ok, board} = Bus.board(opts)
      assert board["total_facts"] == 1

      assert [line] = Enum.filter(board["facts"], &(&1["topic"] == "ci"))
      assert line["text"] == "main is green"
      assert is_integer(line["id"])
    end

    test "the board consumes nothing: two boards agree, and a later read drains every message",
         %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]

      assert :ok = Bus.post("fact", "green", opts ++ [topic: "ci"])
      assert :ok = Bus.post("fact", "rolling", opts ++ [topic: "deploy"])
      assert :ok = Bus.post("note", "heads up", opts ++ [topic: "misc"])

      assert {:ok, board1} = Bus.board(opts)
      assert {:ok, board2} = Bus.board(opts)

      # Idempotent on the scoped state it projects -- reading it changed nothing.
      assert board1["facts"] == board2["facts"]
      assert board1["total_facts"] == board2["total_facts"] and board1["total_facts"] == 2

      # Nothing was consumed: a subsequent read still sees ALL pending messages
      # (the 3 posts across the scope consumer).
      assert {:ok, messages} = Bus.read(opts)
      texts = Enum.map(messages, & &1.text)
      assert "green" in texts
      assert "rolling" in texts
      assert "heads up" in texts
    end

    test "the roster reuses who's presence path -- the caller appears with stable identity",
         %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]

      # Establish presence + a durable name, exactly as who reads it.
      assert :ok = Bus.name("boardster", opts)

      assert {:ok, board} = Bus.board(opts)
      assert [row] = Enum.filter(board["roster"], &(&1["session"] == session))
      assert row["name"] == "boardster"
      assert row["liveness"] == "active"

      # The board roster is the SAME roster who renders (same presence source).
      assert {:ok, sessions} = Bus.who(conn: conn, session: session)
      assert Enum.any?(sessions, &(&1["session"] == session and &1["name"] == "boardster"))
    end

    test "a 60 KiB fact renders as a stub carrying its id, never verbatim", %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]
      body = "sixty-kib #{session} " <> String.duplicate("x", 60 * 1024)

      assert :ok = Bus.post("fact", body, opts ++ [topic: "doc"])

      assert {:ok, board} = Bus.board(opts)
      assert [stub] = Enum.filter(board["facts"], &(&1["topic"] == "doc"))
      assert stub["type"] == "stub"
      assert stub["bytes"] == byte_size(body)
      assert is_integer(stub["id"])
      refute Map.has_key?(stub, "text")
    end

    test "the fact section is bounded regardless of topic count", %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]
      topics = Digest.max_lines() + 12

      for i <- 1..topics do
        assert :ok = Bus.post("fact", "value #{i}", opts ++ [topic: "topic-#{i}"])
      end

      assert {:ok, board} = Bus.board(opts)
      assert board["total_facts"] == topics
      assert length(board["facts"]) <= Digest.max_lines()
      assert List.last(board["facts"])["type"] == "overflow"
    end

    test "kazi_bus_board (MCP) returns the board projection, versioned", %{conn: conn} do
      scope = unique_scope()

      assert :ok = Bus.post("fact", "mcp green", conn: conn, scope: scope, topic: "ci")
      assert :ok = Bus.post("fact", "mcp rolling", conn: conn, scope: scope, topic: "deploy")

      assert %{"result" => %{"structuredContent" => result}} =
               call("kazi_bus_board", %{"scope" => scope}, conn: conn)

      assert result["ok"] == true
      assert result["schema_version"] == Kazi.CLI.Schema.schema_version()

      board = result["board"]
      assert board["total_facts"] == 2
      by_topic = Map.new(board["facts"], &{&1["topic"], &1["text"]})
      assert by_topic == %{"ci" => "mcp green", "deploy" => "mcp rolling"}
    end
  end

  defp call(name, arguments, opts) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }

    Server.handle_request(request, opts)
  end

  defp unique_session, do: "t55_board_#{System.unique_integer([:positive])}"
  defp unique_scope, do: "t55board#{System.unique_integer([:positive])}"

  defp parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end
