defmodule Kazi.Providers.HttpProbeTest do
  # Tier 2: real HTTP boundary against a local loopback server, no external
  # network. Each test spins a tiny :gen_tcp listener on 127.0.0.1:<ephemeral>
  # that returns one canned HTTP/1.1 response, points the probe at it, and tears
  # it down. async: false because :httpc shares a default profile process.
  use ExUnit.Case, async: false

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.HttpProbe

  setup do
    :inets.start()
    :ssl.start()
    :ok
  end

  describe "matching response" do
    test "status and body both match → :pass" do
      {port, stop} = start_server(status_line: "200 OK", body: "ok")

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_status: 200, expect_body: "ok"}
        )

      result = HttpProbe.evaluate(predicate, %{})

      assert %PredicateResult{status: :pass, evidence: evidence} = result
      assert evidence.http_status == 200
      assert evidence.body == "ok"
      assert evidence.url == url(port)

      stop.()
    end

    test "body substring (default :contains) matches within a larger body → :pass" do
      {port, stop} = start_server(status_line: "200 OK", body: ~s({"status":"ok","v":1}))

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_body: "\"status\":\"ok\""}
        )

      assert %PredicateResult{status: :pass} = HttpProbe.evaluate(predicate, %{})

      stop.()
    end
  end

  describe "failing assertions" do
    test "wrong body → :fail with evidence" do
      {port, stop} = start_server(status_line: "200 OK", body: "service unavailable")

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_status: 200, expect_body: "ok"}
        )

      result = HttpProbe.evaluate(predicate, %{})

      assert %PredicateResult{status: :fail, evidence: evidence} = result
      assert evidence.http_status == 200
      assert evidence.body == "service unavailable"
      assert [%{assertion: :body, expected: "ok"}] = evidence.assertion_failures

      stop.()
    end

    test "exact body match fails when body merely contains the expected value → :fail" do
      {port, stop} = start_server(status_line: "200 OK", body: "ok now")

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_body: "ok", body_match: :exact}
        )

      assert %PredicateResult{status: :fail} = HttpProbe.evaluate(predicate, %{})

      stop.()
    end

    test "body_match as the STRING \"exact\" (goal-file form) is honored → :fail on substring" do
      # A TOML goal-file can only supply body_match = "exact" (a string, not an
      # atom). It must mean exact equality, otherwise expecting "ok" falsely
      # passes against "not-ok" because "not-ok" CONTAINS "ok". Regression for the
      # T0.12 dogfood false-pass.
      {port, stop} = start_server(status_line: "200 OK", body: "not-ok")

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_body: "ok", body_match: "exact"}
        )

      assert %PredicateResult{status: :fail} = HttpProbe.evaluate(predicate, %{})

      stop.()
    end

    test "wrong status → :fail with status assertion failure" do
      {port, stop} = start_server(status_line: "500 Internal Server Error", body: "boom")

      predicate =
        Predicate.new(:live, :http_probe, config: %{url: url(port), expect_status: 200})

      result = HttpProbe.evaluate(predicate, %{})

      assert %PredicateResult{status: :fail, evidence: evidence} = result
      assert evidence.http_status == 500
      assert [%{assertion: :status, expected: 200, actual: 500}] = evidence.assertion_failures

      stop.()
    end
  end

  describe "request errors" do
    test "connection refused (no server listening) → :error, not :fail" do
      # Reserve a port, then close it so the connect is refused.
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_status: 200, timeout_ms: 1_000}
        )

      result = HttpProbe.evaluate(predicate, %{})

      assert %PredicateResult{status: :error, evidence: evidence} = result
      assert evidence.url == url(port)
      assert is_binary(evidence.reason)
    end

    test "missing url in config → :error" do
      predicate = Predicate.new(:live, :http_probe, config: %{expect_status: 200})

      assert %PredicateResult{status: :error, evidence: %{reason: :missing_url}} =
               HttpProbe.evaluate(predicate, %{})
    end
  end

  test "unsupported predicate kind → :error" do
    predicate = Predicate.new(:x, :mystery)
    assert %PredicateResult{status: :error} = HttpProbe.evaluate(predicate, %{})
  end

  # --- sustained health (T32.10, ADR-0043) -----------------------------------

  describe "sustained health (samples > 1)" do
    test "N consecutive healthy samples → :pass with score = healthy count" do
      {port, stop} =
        start_sequence_server([
          {"200 OK", "ok"},
          {"200 OK", "ok"},
          {"200 OK", "ok"}
        ])

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_status: 200, expect_body: "ok", samples: 3}
        )

      result = HttpProbe.evaluate(predicate, %{})

      assert %PredicateResult{status: :pass, evidence: evidence} = result
      assert evidence.samples_required == 3
      assert evidence.healthy_count == 3
      assert length(evidence.samples) == 3
      # Envelope v2: healthy count is the higher-better gradient.
      assert result.score == 3.0
      assert result.direction == :higher_better

      stop.()
    end

    test "a single transient 200 does NOT pass — one bad sample breaks the run → :fail" do
      # First sample is a healthy 200, the second is a 503; sustained health
      # requires N CONSECUTIVE healthy samples, so the lone good sample fails.
      {port, stop} =
        start_sequence_server([
          {"200 OK", "ok"},
          {"503 Service Unavailable", "down"}
        ])

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_status: 200, expect_body: "ok", samples: 3}
        )

      result = HttpProbe.evaluate(predicate, %{})

      assert %PredicateResult{status: :fail, evidence: evidence} = result
      assert evidence.samples_required == 3
      # Only the first sample was healthy before the streak broke.
      assert evidence.healthy_count == 1
      assert result.score == 1.0
      assert result.direction == :higher_better
      # The breaking sample's assertion failures are surfaced (status 503 ≠ 200).
      assert %{assertion: :status, expected: 200, actual: 503} in evidence.assertion_failures

      stop.()
    end

    test "an unreachable endpoint on the first sample → :error, not :fail" do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_status: 200, samples: 3, timeout_ms: 1_000}
        )

      assert %PredicateResult{status: :error, evidence: evidence} =
               HttpProbe.evaluate(predicate, %{})

      assert evidence.samples_required == 3
      assert evidence.healthy_count == 0
    end

    test "samples: 1 is byte-identical to the single-probe path (no score)" do
      {port, stop} = start_server(status_line: "200 OK", body: "ok")

      predicate =
        Predicate.new(:live, :http_probe,
          config: %{url: url(port), expect_status: 200, expect_body: "ok", samples: 1}
        )

      result = HttpProbe.evaluate(predicate, %{})

      assert %PredicateResult{status: :pass, score: nil, evidence: evidence} = result
      # Single-sample evidence shape: no sustained-health keys.
      refute Map.has_key?(evidence, :samples_required)
      assert evidence.http_status == 200

      stop.()
    end
  end

  # --- local HTTP/1.1 server -------------------------------------------------

  defp url(port), do: "http://127.0.0.1:#{port}/healthz"

  # Spawns a one-shot loopback listener that answers each accepted connection
  # with the canned response, then loops for the next. Returns {port, stop_fun}.
  defp start_server(opts) do
    status_line = Keyword.fetch!(opts, :status_line)
    body = Keyword.fetch!(opts, :body)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    response =
      "HTTP/1.1 #{status_line}\r\n" <>
        "Content-Type: text/plain\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <>
        body

    server =
      spawn_link(fn -> accept_loop(listen, response) end)

    stop = fn ->
      Process.unlink(server)
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
    end

    {port, stop}
  end

  defp accept_loop(listen, response) do
    case :gen_tcp.accept(listen) do
      {:ok, conn} ->
        # Drain the request line/headers (we don't route on them).
        _ = :gen_tcp.recv(conn, 0, 1_000)
        :gen_tcp.send(conn, response)
        :gen_tcp.close(conn)
        accept_loop(listen, response)

      {:error, _} ->
        :ok
    end
  end

  # Spawns a listener that answers each accepted connection with the NEXT response
  # in the list (one per connection), so a sustained-health probe taking N samples
  # sees a controlled sequence of verdicts. Returns {port, stop_fun}.
  defp start_sequence_server(responses) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    encoded =
      Enum.map(responses, fn {status_line, body} ->
        "HTTP/1.1 #{status_line}\r\n" <>
          "Content-Type: text/plain\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n" <>
          "Connection: close\r\n\r\n" <>
          body
      end)

    server = spawn_link(fn -> sequence_accept_loop(listen, encoded) end)

    stop = fn ->
      Process.unlink(server)
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
    end

    {port, stop}
  end

  defp sequence_accept_loop(_listen, []), do: :ok

  defp sequence_accept_loop(listen, [response | rest]) do
    case :gen_tcp.accept(listen) do
      {:ok, conn} ->
        _ = :gen_tcp.recv(conn, 0, 1_000)
        :gen_tcp.send(conn, response)
        :gen_tcp.close(conn)
        sequence_accept_loop(listen, rest)

      {:error, _} ->
        :ok
    end
  end
end
