defmodule Kazi.Bus.BusGetTest do
  @moduledoc """
  T55.6 (ADR-0072 decision 3): `kazi bus get <id>` -- the deliberate pull for a
  stubbed body.

  The digest (T55.1) collapses a body over the 1024-byte render threshold into
  a one-line stub carrying its stream-seq `id`; `get` dereferences that id back
  to the full body, on purpose, without disturbing anyone's read cursor.

  UNTAGGED (always run, no NATS needed): the no-daemon error path.

  `:nats`-TAGGED (excluded by default; `NATS_URL` required), mirroring
  `Kazi.Bus.MvpTest` -- each test provisions for itself and passes `opts[:conn]`
  directly, so it exercises the real stream without a running `kazi daemon`:

    * a 60 KiB post stubs in the digest, and `get` returns the body
      byte-identical to what was posted;
    * an unknown id is a clean one-line error, never a crash;
    * `get` consumes NOTHING -- a subsequent `read` still delivers the message.
  """
  use ExUnit.Case, async: false

  alias Kazi.Bus
  alias Kazi.Bus.Digest
  alias Kazi.Bus.Provision
  alias Kazi.MCP.Server

  # ===========================================================================
  # Untagged
  # ===========================================================================

  describe "no daemon" do
    test "get reports {:error, :no_daemon} against a missing socket" do
      opts = [sock_path: "/tmp/kazi_bus_get_missing_#{System.unique_integer([:positive])}.sock"]

      assert {:error, :no_daemon} = Bus.get(1, opts)
    end
  end

  # ===========================================================================
  # :nats-tagged (excluded by default; NATS_URL required)
  # ===========================================================================

  describe "get/2 against a real NATS JetStream server" do
    @describetag :nats

    setup :nats_conn

    test "a 60 KiB post stubs in the digest, and get returns the body byte-identical", %{
      conn: conn
    } do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]
      body = "sixty-kib #{session} " <> String.duplicate("x", 60 * 1024)

      assert :ok = Bus.post("note", body, opts ++ [topic: "doc"])

      # It really stubs in the digest (the already-shipped behavior still holds).
      assert {:ok, messages} = Bus.peek(opts)
      assert [msg] = Enum.filter(messages, &(&1.topic == "doc"))
      %{"lines" => lines} = Digest.render(messages)
      assert [stub] = Enum.filter(lines, &(&1["type"] == "stub"))
      assert stub["id"] == msg.id
      refute Map.has_key?(stub, "text")

      # The deliberate pull: get by that id returns the FULL body, byte-identical.
      assert {:ok, fetched} = Bus.get(msg.id, conn: conn, session: unique_session())
      assert fetched["text"] == body
      assert fetched["bytes"] == byte_size(body)
      assert fetched["id"] == msg.id
      assert fetched["kind"] == "note"
      assert fetched["topic"] == "doc"
    end

    test "an unknown id is a clean one-line error, never a crash", %{conn: conn} do
      assert {:error, {:unknown_message, 999_999}} =
               Bus.get(999_999, conn: conn, session: unique_session())
    end

    test "get consumes NOTHING -- a subsequent read still delivers the message", %{conn: conn} do
      recipient = live_session(conn)

      assert {:ok, receipt} =
               Bus.tell(recipient, "still here", conn: conn, session: unique_session())

      # Get the body first: this must not advance the recipient's cursor.
      assert {:ok, fetched} = Bus.get(receipt.id, conn: conn, session: unique_session())
      assert fetched["text"] == "still here"

      # The recipient's own read STILL delivers it (get acked nothing).
      assert {:ok, messages} = drain_all(conn, recipient)
      assert msg = Enum.find(messages, &(&1.text == "still here"))
      assert msg.id == receipt.id
    end

    test "get returns a small body whole regardless of the surface preview rule", %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      opts = [conn: conn, session: session, scope: scope]

      assert :ok = Bus.post("fact", "small body", opts ++ [topic: "ci"])
      assert {:ok, messages} = Bus.read(opts)
      assert msg = Enum.find(messages, &(&1.text == "small body"))

      assert {:ok, fetched} = Bus.get(msg.id, conn: conn, session: unique_session())
      assert fetched["text"] == "small body"
    end
  end

  describe "kazi_bus_get (MCP) against a real NATS JetStream server" do
    @describetag :nats

    setup :nats_conn

    test "default returns a bounded preview; full: true the whole body", %{conn: conn} do
      session = unique_session()
      scope = unique_scope()
      body = "mcp-get " <> String.duplicate("y", 60 * 1024)

      assert :ok =
               Bus.post("note", body, conn: conn, session: session, scope: scope, topic: "doc")

      assert {:ok, messages} = Bus.peek(conn: conn, session: session, scope: scope)
      assert msg = Enum.find(messages, &(&1.topic == "doc"))

      # Default: a bounded preview, truncated flagged, full size still reported.
      assert %{"result" => %{"structuredContent" => preview}} =
               call("kazi_bus_get", %{"id" => msg.id}, conn: conn)

      assert preview["ok"] == true
      assert preview["schema_version"] == Kazi.CLI.Schema.schema_version()
      assert preview["message"]["truncated"] == true
      assert byte_size(preview["message"]["text"]) <= Digest.render_threshold_bytes()
      assert preview["message"]["bytes"] == byte_size(body)

      # full: true -- the whole body, byte-identical.
      assert %{"result" => %{"structuredContent" => full}} =
               call("kazi_bus_get", %{"id" => msg.id, "full" => true}, conn: conn)

      assert full["message"]["truncated"] == false
      assert full["message"]["text"] == body
    end

    test "an unknown id is a structured unknown_message tool error", %{conn: conn} do
      assert %{"result" => %{"isError" => true, "structuredContent" => content}} =
               call("kazi_bus_get", %{"id" => 999_999}, conn: conn)

      assert content["reason"] == "unknown_message"
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp nats_conn(_context) do
    {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
    {:ok, conn} = Gnat.start_link(%{host: host, port: port})
    on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
    :ok = Provision.provision(conn)
    %{conn: conn}
  end

  defp live_session(conn) do
    session = unique_session()
    {:ok, _} = Bus.who(conn: conn, session: session)
    session
  end

  # L-0040: Bus pulls in batches of 100 and the shared test scope is busy, so a
  # single read does not necessarily surface a given message -- drain until empty.
  defp drain_all(conn, session), do: drain_all(conn, session, [])

  defp drain_all(conn, session, acc) do
    case Bus.read(conn: conn, session: session, scope: "machine") do
      {:ok, []} -> {:ok, acc}
      {:ok, messages} -> drain_all(conn, session, acc ++ messages)
      {:error, reason} -> {:error, reason}
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

  defp unique_session, do: "t55get-#{System.unique_integer([:positive])}"
  defp unique_scope, do: "t55getscope#{System.unique_integer([:positive])}"

  defp parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end
