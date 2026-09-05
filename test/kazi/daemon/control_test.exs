defmodule Kazi.Daemon.ControlTest do
  @moduledoc """
  T52.2 (ADR-0068 decision 3): the schema-version handshake on the control
  socket. Tier 2 — real SQLite boundary: the `ping` reply's `schema_vsn` is read
  from the stamped `kazi_schema_meta` row through `Kazi.ReadModel.Migrate`.
  """
  use ExUnit.Case, async: false

  alias Kazi.Daemon.Control
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp stamp!(repo, version) do
    Ecto.Adapters.SQL.query!(
      repo,
      "CREATE TABLE IF NOT EXISTS kazi_schema_meta (version INTEGER NOT NULL)",
      []
    )

    Ecto.Adapters.SQL.query!(repo, "DELETE FROM kazi_schema_meta", [])

    Ecto.Adapters.SQL.query!(repo, "INSERT INTO kazi_schema_meta (version) VALUES (?1)", [version])
  end

  defp ping(opts) do
    Control.handle(%{"op" => "ping"}, Keyword.merge([started_at: 0], opts))
  end

  test "the ping reply carries schema_vsn equal to the stamped migration version" do
    stamp!(Repo, 20_260_709_210_000)

    assert ping(repo: Repo)["schema_vsn"] == 20_260_709_210_000
  end

  test "the ping reply always carries bus_vsn (T58.2, #1227) regardless of repo availability" do
    assert ping(repo: Repo)["bus_vsn"] == Kazi.Bus.ProtocolSkew.required_bus_vsn()
    assert ping(repo: :no_such_repo)["bus_vsn"] == Kazi.Bus.ProtocolSkew.required_bus_vsn()
  end

  test "every pre-existing ping field is unchanged and an old-client decode still succeeds" do
    resp = ping(repo: Repo)

    assert resp["ok"] == true
    assert is_binary(resp["vsn"])
    assert is_integer(resp["pid"])
    assert is_integer(resp["uptime_s"])

    # schema_vsn is purely additive: the reply still encodes to one JSON line and
    # an old client (which never looks for schema_vsn) decodes it unchanged.
    assert {:ok, decoded} = Jason.decode(Jason.encode!(resp))
    assert decoded["ok"] == true
    assert decoded["vsn"] == resp["vsn"]
    assert decoded["pid"] == resp["pid"]
  end

  test "an unavailable repo omits schema_vsn rather than crashing the ping" do
    resp = ping(repo: :no_such_repo)

    assert resp["ok"] == true
    refute Map.has_key?(resp, "schema_vsn")
  end

  describe "nats_health (T69.5, #1684)" do
    test "is present, all-clear-shaped, and additive when no nats_name is configured" do
      resp = ping(repo: Repo)

      # Every pre-existing field is still there, unchanged.
      assert resp["ok"] == true
      assert is_binary(resp["vsn"])
      assert resp["bus_vsn"] == Kazi.Bus.ProtocolSkew.required_bus_vsn()

      assert %{
               "restart_loop" => false,
               "exits_in_window" => 0,
               "bind_conflict" => nil
             } = resp["nats_health"]
    end

    test "surfaces the live Kazi.Daemon.Nats process's restart-loop window and last bind-conflict" do
      name = :"control_test_nats_health_#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase({Kazi.Daemon.Nats, :health, name}) end)

      # `Kazi.Daemon.Nats.health/1` is `:persistent_term`-backed and keyed by
      # name alone -- no real GenServer needs to be running for `ping` to
      # report on it, which is the whole point (see `Nats.health/1`'s doc).
      :persistent_term.put(
        {Kazi.Daemon.Nats, :health, name},
        %{
          restart_loop: true,
          exits_in_window: 4,
          exit_window_ms: 60_000,
          bind_conflict: %{
            disposition: :orphan,
            holder_pid: 12_345,
            port: 4223,
            detected_at: ~U[2026-09-05 00:00:00Z]
          },
          last_exit_at: ~U[2026-09-05 00:00:01Z],
          last_exit_monotonic_ms: System.monotonic_time(:millisecond)
        }
      )

      resp = ping(repo: Repo, nats_name: name)

      assert resp["nats_health"] == %{
               "restart_loop" => true,
               "exits_in_window" => 4,
               "exit_window_ms" => 60_000,
               "bind_conflict" => %{
                 "disposition" => "orphan",
                 "holder_pid" => 12_345,
                 "port" => 4223,
                 "detected_at" => "2026-09-05T00:00:00Z"
               },
               "last_exit_at" => "2026-09-05T00:00:01Z"
             }

      # Purely additive: an old client that never looks for `nats_health`
      # still decodes the SAME reply unchanged.
      assert {:ok, decoded} = Jason.decode(Jason.encode!(resp))
      assert decoded["ok"] == true
      assert decoded["nats_health"]["restart_loop"] == true
    end
  end
end
