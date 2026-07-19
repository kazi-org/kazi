defmodule Kazi.Coordination.Lease.NatsTest do
  @moduledoc """
  The real NATS JetStream KV `Kazi.Coordination.Lease` backend (T3.1b).

  This proves `Kazi.Coordination.Lease.Nats` satisfies the **same** narrow lease
  contract as the in-memory default by running the **same** shared,
  backend-agnostic conformance suite (`Kazi.Coordination.LeaseContract`) against a
  *real* NATS server — the one place in the suite a live NATS client is exercised.

  ## Integration-tagged — excluded by default

  Every test here is tagged `@moduletag :nats`. `test/test_helper.exs` excludes the
  `:nats` tag unless `NATS_URL` is set, so the standard `mix test` stays hermetic
  (no NATS server, no network). To run it against a real NATS JetStream server:

      NATS_URL=nats://127.0.0.1:4222 mix test --include nats

  `--include nats` overrides the default exclusion; `NATS_URL` (`nats://host:port`)
  is parsed for the `Gnat` connection. Each test provisions a *fresh*, uniquely
  named KV bucket so the conformance suite's per-test isolation holds, and the
  contract drives a virtual clock (explicit `:now_ms`) so TTL boundaries are exact
  even against real time.
  """

  use ExUnit.Case, async: false

  @moduletag :nats

  alias Kazi.Coordination.Lease.Nats

  # The shared conformance suite, instantiated against the NATS backend. Each test
  # connects to NATS and provisions a *fresh*, uniquely named KV bucket so leases
  # never leak between tests; the contract supplies the injected `:now_ms`, so TTL
  # boundaries are decided by the stored `expires_at_ms`, not by NATS wall time.
  use Kazi.Coordination.LeaseContract,
    backend: Kazi.Coordination.Lease.Nats,
    setup_lease_backend: fn ->
      {host, port} =
        Kazi.Coordination.Lease.NatsTest.parse_nats_url(System.fetch_env!("NATS_URL"))

      {:ok, conn} = Gnat.start_link(%{host: host, port: port})
      ExUnit.Callbacks.on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)

      bucket = "kazi_lease_test_" <> Integer.to_string(System.unique_integer([:positive]))
      base_opts = [conn: conn, bucket: bucket]
      # The bucket's max-age is a defense-in-depth GC; logical TTL is the injected
      # clock. 1s is well past the virtual TTLs the contract uses (≤1s windows are
      # decided by `expires_at_ms`, not by NATS time).
      :ok = Nats.ensure_bucket(base_opts, 1_000)
      base_opts
    end

  @doc false
  # Parse `nats://host:port` into `{host, port}` for `Gnat.start_link/1`. Public so
  # the `setup_lease_backend` closure (spliced into the generated setup) can call it.
  def parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end
