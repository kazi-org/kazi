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
end
