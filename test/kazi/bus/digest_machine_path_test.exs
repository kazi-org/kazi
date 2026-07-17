defmodule Kazi.Bus.DigestMachinePathTest do
  @moduledoc """
  T55.1 (ADR-0072): the digest protects every machine-readable path, against a
  REAL NATS JetStream server.

  `:nats`-tagged (excluded by default; `NATS_URL` required), mirroring
  `Kazi.Bus.MvpTest`: each test provisions for itself and passes `opts[:conn]`
  directly, so it exercises the real stream without a running `kazi daemon`.
  Tests isolate from one another (and from stream-history replay on fresh
  durables) by using a UNIQUE custom scope per test.

  Covers the task's acceptance: 200 posted messages across 3 kinds digest to
  <=40 lines with exact counts; a 60 KiB body renders as a stub carrying its
  stream-seq id (never verbatim, even at `sev: interrupt`); directed and
  interrupt messages render verbatim; `--full`/`full: true` returns every
  message unabridged; the envelope carries `schema_version`; returned ids are
  dereferenceable stream sequences.
  """
  use ExUnit.Case, async: false

  alias Gnat.Jetstream.API.Stream, as: JStream
  alias Kazi.Bus
  alias Kazi.Bus.Digest
  alias Kazi.Bus.Provision
  alias Kazi.MCP.Server

  @moduletag :nats_group

  describe "the machine path against a real JetStream server" do
    @describetag :nats

    setup do
      {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
      {:ok, conn} = Gnat.start_link(%{host: host, port: port})
      on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
      :ok = Provision.provision(conn)
      %{conn: conn}
    end

    test "200 posted messages across 3 kinds digest to <=40 lines with exact counts", %{
      conn: conn
    } do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]

      for i <- 1..200 do
        kind = Enum.at(["fact", "note", "announce"], rem(i, 3))
        assert :ok = Bus.post(kind, "backlog #{i}", Keyword.put(opts, :topic, "load"))
      end

      messages = drain_all(opts)
      assert length(messages) == 200
      assert Enum.all?(messages, fn m -> is_integer(m.id) end)

      # The CLI --json envelope: digest by default, versioned.
      payload = Kazi.CLI.bus_read_payload(messages, full: false)
      assert payload["ok"] == true
      assert payload["schema_version"] == Kazi.CLI.Schema.schema_version()
      refute Map.has_key?(payload, "messages")

      %{"total" => 200, "lines" => lines} = payload["digest"]
      assert length(lines) <= Digest.max_lines()
      assert Enum.all?(lines, &(&1["type"] == "count"))
      assert Enum.sum(Enum.map(lines, & &1["count"])) == 200
    end

    test "a 60 KiB body is a stub carrying its dereferenceable stream-seq id, never verbatim",
         %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]
      body = "sixty-kib #{session} " <> String.duplicate("x", 60 * 1024)

      # Even at sev: interrupt the stub rule wins (ADR-0072 d7).
      assert :ok = Bus.post("note", body, opts ++ [topic: "doc", sev: "interrupt"])

      assert {:ok, messages} = Bus.read(opts)
      assert [msg] = Enum.filter(messages, fn m -> m.topic == "doc" end)
      assert is_integer(msg.id)

      %{"lines" => lines} = Digest.render(messages)
      assert [stub] = Enum.filter(lines, &(&1["type"] == "stub"))
      assert stub["id"] == msg.id
      assert stub["bytes"] == byte_size(body)
      refute Map.has_key?(stub, "text")
      refute Jason.encode!(lines) =~ String.duplicate("x", 1024)

      # The id is a real, dereferenceable stream sequence: a direct stream
      # fetch by seq returns the full body (the deliberate pull T55.6 wraps).
      assert {:ok, %{data: ^body}} =
               JStream.get_message(conn, Provision.stream_name(), %{seq: msg.id})
    end

    test "a directed message and a sev: interrupt post render verbatim", %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]

      # T55.5: tell resolves recipients against the roster -- establish
      # the recipient's presence first (any bus call does).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      assert :ok = Bus.tell(session, "directed #{session}", conn: conn, scope: scope)
      assert :ok = Bus.post("note", "urgent #{session}", opts ++ [topic: "ci", sev: "interrupt"])
      assert :ok = Bus.post("fact", "routine #{session}", opts ++ [topic: "ci"])

      assert {:ok, messages} = Bus.read(opts)
      %{"lines" => lines} = Digest.render(messages)

      assert Enum.any?(lines, fn line ->
               line["type"] == "verbatim" and line["kind"] == "msg" and
                 line["text"] == "directed #{session}" and is_integer(line["id"])
             end)

      assert Enum.any?(lines, fn line ->
               line["type"] == "verbatim" and line["sev"] == "interrupt" and
                 line["text"] == "urgent #{session}"
             end)

      refute Enum.any?(lines, fn line ->
               line["type"] == "verbatim" and line["text"] == "routine #{session}"
             end)
    end

    test "kazi_bus_read (MCP) returns the digest by default; full: true every message unabridged",
         %{conn: conn} do
      scope = unique_scope()
      body = "mcp-doc " <> String.duplicate("y", 60 * 1024)

      assert :ok = Bus.post("note", body, conn: conn, scope: scope, topic: "doc")
      assert :ok = Bus.post("fact", "small mcp fact", conn: conn, scope: scope, topic: "ci")

      # Default: the bounded digest, versioned, no messages array.
      assert %{"result" => %{"structuredContent" => digest_result}} =
               call("kazi_bus_read", %{"peek" => true, "scope" => scope}, conn: conn)

      assert digest_result["ok"] == true
      assert digest_result["schema_version"] == Kazi.CLI.Schema.schema_version()
      refute Map.has_key?(digest_result, "messages")

      %{"total" => 2, "lines" => lines} = digest_result["digest"]
      assert length(lines) <= Digest.max_lines()
      assert [stub] = Enum.filter(lines, &(&1["type"] == "stub"))
      refute Map.has_key?(stub, "text")

      # full: true is the documented escape -- every message unabridged.
      assert %{"result" => %{"structuredContent" => full_result}} =
               call("kazi_bus_read", %{"peek" => true, "full" => true, "scope" => scope},
                 conn: conn
               )

      assert full_result["schema_version"] == Kazi.CLI.Schema.schema_version()
      refute Map.has_key?(full_result, "digest")

      messages = full_result["messages"]
      assert Enum.any?(messages, fn m -> m.text == body end)
      assert Enum.any?(messages, fn m -> m.text == "small mcp fact" end)
      assert Enum.all?(messages, fn m -> is_integer(m.id) end)
    end

    test "kazi_bus_watch (MCP) renders its result through the digest, and times out with one",
         %{conn: conn} do
      scope = unique_scope()

      assert :ok = Bus.post("note", "wake the watcher", conn: conn, scope: scope, topic: "ci")

      # T54.9: watch anchors to NOW by default, so a pre-posted message is
      # backlog and would not satisfy it -- this test is about the DIGEST
      # rendering, so opt into the drain-first escape explicitly.
      assert %{"result" => %{"structuredContent" => result}} =
               call(
                 "kazi_bus_watch",
                 %{"timeout" => 5, "scope" => scope, "since" => "all"},
                 conn: conn
               )

      assert result["ok"] == true
      assert result["schema_version"] == Kazi.CLI.Schema.schema_version()
      assert %{"total" => 1, "lines" => [%{"type" => "count", "count" => 1}]} = result["digest"]

      # Expiry: timed_out with an EMPTY digest (agents branch on timed_out).
      assert %{"result" => %{"structuredContent" => timed_out}} =
               call("kazi_bus_watch", %{"timeout" => 1, "scope" => scope}, conn: conn)

      assert timed_out["ok"] == true
      assert timed_out["timed_out"] == true
      assert timed_out["digest"] == %{"total" => 0, "lines" => []}
    end
  end

  # Pull the durables until they run dry: `Kazi.Bus` pulls in batches of 100,
  # so a 200-message backlog needs more than one read.
  defp drain_all(opts, acc \\ []) do
    case Bus.read(opts) do
      {:ok, []} -> acc
      {:ok, messages} -> drain_all(opts, acc ++ messages)
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

  defp unique_session, do: "t55_digest_#{System.unique_integer([:positive])}"
  defp unique_scope, do: "t55scope#{System.unique_integer([:positive])}"

  defp parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end
