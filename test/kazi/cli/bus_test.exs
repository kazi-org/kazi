defmodule Kazi.CLI.BusTest do
  @moduledoc """
  Issues #1060/#1059: the `kazi bus` CLI contract.

  UNTAGGED tests (always run, no NATS needed): argv parsing for `bus post`'s
  <kind> default/validation, per-verb `bus <verb> --help` text, and the
  no-daemon dispatch path (mirrors `Kazi.CLI.DaemonTest`'s Tier 2 pattern --
  a tmp-scoped `KAZI_STATE_DIR` so this never touches a developer's real
  daemon socket).

  `:nats`-TAGGED tests (excluded by default; `NATS_URL` required) mirror
  `Kazi.Bus.MvpTest`: they pass `opts[:conn]` straight to `Kazi.Bus`, the same
  seam that lets a test exercise the real bus without a running `kazi daemon`.
  They cover `bus peek`'s non-destructive contract and stdout/stderr hygiene.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Bus

  # ===========================================================================
  # Untagged: parse/1 -- `bus post`'s <kind> default and validation (#1060)
  # ===========================================================================

  describe "parse/1 -- bus post <kind> default and validation" do
    test "`bus post <text>` (no kind) parses with a single positional" do
      assert {:bus, "post", ["hello"], _opts} = Kazi.CLI.parse(["bus", "post", "hello"])
    end

    test "`bus post <kind> <text>` parses with both positionals" do
      assert {:bus, "post", ["fact", "hello"], _opts} =
               Kazi.CLI.parse(["bus", "post", "fact", "hello"])
    end

    test "`bus peek` parses as its own verb" do
      assert {:bus, "peek", [], _opts} = Kazi.CLI.parse(["bus", "peek"])
    end

    test "`bus read --peek` threads the peek flag through" do
      assert {:bus, "read", [], opts} = Kazi.CLI.parse(["bus", "read", "--peek"])
      assert opts[:peek] == true
    end

    test "`bus read` without --peek defaults peek to false" do
      assert {:bus, "read", [], opts} = Kazi.CLI.parse(["bus", "read"])
      assert opts[:peek] == false
    end

    test "`bus watch --since <value>` threads the since flag through (T54.9)" do
      assert {:bus, "watch", [], opts} = Kazi.CLI.parse(["bus", "watch", "--since", "all"])
      assert opts[:since] == "all"
    end

    test "`bus name <nickname>` parses as its own verb (T55.5)" do
      assert {:bus, "name", ["worker-a"], _opts} = Kazi.CLI.parse(["bus", "name", "worker-a"])
    end

    test "`bus tell --session-name <n>` threads the sender identity through (T55.5)" do
      assert {:bus, "tell", ["worker-a", "hi"], opts} =
               Kazi.CLI.parse(["bus", "tell", "worker-a", "hi", "--session-name", "supervisor"])

      assert opts[:session_name] == "supervisor"
    end
  end

  # ===========================================================================
  # Untagged: T55.1 (ADR-0072) -- the digest is the default --json shape;
  # --full is the documented escape. Pinned through the payload seam so no
  # daemon is needed.
  # ===========================================================================

  describe "parse/1 -- bus read|peek|watch --full (ADR-0072)" do
    test "`bus read --full` threads the full flag through" do
      assert {:bus, "read", [], opts} = Kazi.CLI.parse(["bus", "read", "--full"])
      assert opts[:full] == true
    end

    test "`bus peek` / `bus watch` accept --full; default is false" do
      assert {:bus, "peek", [], opts} = Kazi.CLI.parse(["bus", "peek", "--full"])
      assert opts[:full] == true

      assert {:bus, "watch", [], opts} = Kazi.CLI.parse(["bus", "watch"])
      assert opts[:full] == false
    end
  end

  describe "bus_read_payload/2 -- the --json envelope (ADR-0072 d1/d6)" do
    defp synthetic_message(id, kind, text) do
      %{
        id: id,
        kind: kind,
        topic: "ci",
        text: text,
        sev: "info",
        session: "s",
        machine: "m",
        ts: "2026-07-16T00:00:00Z",
        scope: "machine"
      }
    end

    test "the digest is the default: bounded lines, exact counts, schema_version" do
      messages =
        for id <- 1..200 do
          synthetic_message(id, Enum.at(["fact", "note", "announce"], rem(id, 3)), "m#{id}")
        end

      payload = Kazi.CLI.bus_read_payload(messages, full: false)

      assert payload["ok"] == true
      assert payload["schema_version"] == Kazi.CLI.Schema.schema_version()
      refute Map.has_key?(payload, "messages")

      %{"total" => 200, "lines" => lines} = payload["digest"]
      assert length(lines) <= Kazi.Bus.Digest.max_lines()
      assert Enum.sum(Enum.map(lines, & &1["count"])) == 200
    end

    test "--full returns every message unabridged (today's shape, plus the version pin)" do
      messages = [synthetic_message(1, "note", "hello")]

      payload = Kazi.CLI.bus_read_payload(messages, full: true)

      assert payload["ok"] == true
      assert payload["schema_version"] == Kazi.CLI.Schema.schema_version()
      assert payload["messages"] == messages
      refute Map.has_key?(payload, "digest")
    end
  end

  describe "kazi bus read --help -- documents the digest default and --full" do
    test "read/peek/watch help name --full and the digest" do
      for verb <- ["read", "peek", "watch"] do
        output = capture_io(fn -> assert Kazi.CLI.run(["bus", verb, "--help"], []) == 0 end)
        assert output =~ "--full", "`bus #{verb} --help` must document --full"
        assert output =~ "digest", "`bus #{verb} --help` must describe the digest"
      end
    end
  end

  # ===========================================================================
  # Untagged: `bus <verb> --help` -- per-verb usage, not the generic block
  # ===========================================================================

  describe "kazi bus <verb> --help -- per-verb usage" do
    test "`bus post --help` prints post's own signature, not the generic usage" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "post", "--help"], []) == 0 end)

      assert output =~ "kazi bus post"
      assert output =~ "fact"
      refute output =~ "kazi apply <goal-file>"
      refute output =~ "USAGE:"
    end

    test "`bus read --help` prints read's own signature, not the generic usage" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "read", "--help"], []) == 0 end)

      assert output =~ "kazi bus read"
      assert output =~ "--peek"
      refute output =~ "kazi apply <goal-file>"
    end

    test "`bus peek --help` prints peek's own signature, not the generic usage" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "peek", "--help"], []) == 0 end)

      assert output =~ "kazi bus peek"
      refute output =~ "kazi apply <goal-file>"
    end

    test "`bus tell --help` prints tell's own signature, not the generic usage" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "tell", "--help"], []) == 0 end)

      assert output =~ "kazi bus tell"
      refute output =~ "kazi apply <goal-file>"
    end

    test "`bus who --help` prints who's own signature, not the generic usage" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "who", "--help"], []) == 0 end)

      assert output =~ "kazi bus who"
      refute output =~ "kazi apply <goal-file>"
    end

    test "`bus watch --help` documents --since and the exit-3 timeout contract (T54.9)" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "watch", "--help"], []) == 0 end)

      assert output =~ "kazi bus watch"
      assert output =~ "--since"
      assert output =~ "exits 3"
    end

    test "`bus name --help` prints name's own signature, not the generic usage (T55.5)" do
      output = capture_io(fn -> assert Kazi.CLI.run(["bus", "name", "--help"], []) == 0 end)

      assert output =~ "kazi bus name"
      assert output =~ "nickname"
      refute output =~ "kazi apply <goal-file>"
    end
  end

  # ===========================================================================
  # Untagged: dispatch against a clean no-daemon state (kind default/validation
  # happens BEFORE any daemon connection is attempted)
  # ===========================================================================

  describe "kazi bus post -- no daemon running" do
    setup do
      state_dir =
        Path.join(System.tmp_dir!(), "kazi_cli_bus_test_#{System.unique_integer([:positive])}")

      previous = System.get_env("KAZI_STATE_DIR")
      System.put_env("KAZI_STATE_DIR", state_dir)

      on_exit(fn ->
        if previous,
          do: System.put_env("KAZI_STATE_DIR", previous),
          else: System.delete_env("KAZI_STATE_DIR")
      end)

      :ok
    end

    test "post without an explicit kind defaults to `fact` and reaches the no-daemon path" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "post", "hello"], []) == 1
        end)

      assert output =~ "no daemon running"
    end

    test "post with an explicit valid kind reaches the no-daemon path" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "post", "fact", "hello"], []) == 1
        end)

      assert output =~ "no daemon running"
    end

    test "post with an explicit UNKNOWN kind fails fast with a usage error enumerating valid kinds" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "post", "bogus-kind", "hello"], []) == 1
        end)

      assert output =~ "unknown bus kind"
      assert output =~ "fact"
      assert output =~ "announce"
      refute output =~ "no daemon running"
    end

    test "watch with an invalid --since fails fast with a usage error (T54.9)" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "watch", "--since", "yesterday"], []) == 1
        end)

      assert output =~ "--since"
    end

    test "`bus name <nickname>` reaches the no-daemon path (T55.5)" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "name", "worker-a"], []) == 1
        end)

      assert output =~ "no daemon running"
    end

    test "`bus name` with no nickname is a one-line usage error, not a daemon error" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "name"], []) == 1
        end)

      assert output =~ "nickname"
      refute output =~ "no daemon running"
    end

    test "an invalid nickname is rejected client-side with a one-line error" do
      output =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["bus", "name", "@not-a-team"], []) == 1
        end)

      assert output =~ "invalid nickname"
      refute output =~ "no daemon running"
    end
  end

  # ===========================================================================
  # :nats-tagged (excluded by default; NATS_URL required): peek's
  # non-destructive contract (#1059) and stdout/stderr hygiene (#1060 "Also")
  # ===========================================================================

  @moduletag :nats_group

  describe "against a real NATS JetStream server" do
    @describetag :nats

    setup do
      {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
      {:ok, conn} = Gnat.start_link(%{host: host, port: port})
      on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
      :ok = Kazi.Bus.Provision.provision(conn)
      %{conn: conn}
    end

    test "peek shows pending messages without consuming them; read still consumes them", %{
      conn: conn
    } do
      session = unique_session()
      text = "peek me #{session}"
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.post("note", text, opts)

      assert {:ok, first_peek} = Bus.peek(opts)
      assert Enum.any?(first_peek, fn m -> m.text == text end)

      assert {:ok, second_peek} = Bus.peek(opts)
      assert Enum.any?(second_peek, fn m -> m.text == text end)

      assert {:ok, read_messages} = Bus.read(opts)
      assert Enum.any?(read_messages, fn m -> m.text == text end)

      assert {:ok, second_read} = Bus.read(opts)
      refute Enum.any?(second_read, fn m -> m.text == text end)
    end

    test "stdout carries only message payloads -- a housekeeping log line lands on stderr" do
      messages = [
        %{kind: "note", topic: "ci", text: "payload one", sev: "info"},
        %{kind: "note", topic: "ci", text: "payload two", sev: "interrupt"}
      ]

      stdout =
        capture_io(fn ->
          require Logger

          Logger.warning(
            "Skipped cleanup of older version (v1.138.0): still in use by a running process"
          )

          %{verbatim: verbatim, digest: digest} = Kazi.Bus.Digest.summarize(messages)
          Enum.each(verbatim ++ digest, &IO.puts/1)
        end)

      assert stdout == "[note] payload two\n1 note/ci\n"
      refute stdout =~ "Skipped cleanup"
    end
  end

  defp unique_session, do: "bus_cli_test_#{System.unique_integer([:positive])}"

  defp parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host, uri.port}
  end
end
