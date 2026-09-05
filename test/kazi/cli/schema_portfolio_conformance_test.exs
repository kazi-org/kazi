defmodule Kazi.CLI.SchemaPortfolioConformanceTest do
  @moduledoc """
  T69.9: `kazi schema portfolio` must describe the REAL shape `kazi portfolio
  --json` emits (the private `portfolio_json/1` builder in `Kazi.CLI`), not a
  hand-maintained guess that can drift from it. This pins that conformance:
  every top-level field the schema-as-data descriptor (`Kazi.CLI.Schema`)
  documents for `"portfolio"` must actually appear in a real `portfolio --json`
  invocation's decoded output, and vice versa — a field added to one side
  without the other fails here.

  HERMETIC: drives the real `Kazi.CLI.run/2` against the test SQLite Sandbox
  read-model; the cross-machine bus fetch is stubbed to `[]` so no daemon is
  needed (mirrors `Kazi.CLIPortfolioTest`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.CLI.Schema
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> [] end)
    on_exit(fn -> Application.delete_env(:kazi, :remote_run_facts_fetcher) end)
    :ok
  end

  test "portfolio is an advertised result-schema command" do
    assert "portfolio" in Schema.commands()
  end

  test "schema fetch returns a well-formed descriptor with at least one field" do
    assert {:ok, schema} = Schema.fetch("portfolio")
    assert schema.command == "portfolio"
    assert schema.schema_version == Schema.schema_version()
    assert [_ | _] = schema.fields
    assert Enum.all?(schema.fields, &(is_binary(&1.name) and &1.name != ""))
  end

  test "kazi schema portfolio (CLI surface) parses and matches the schema-as-data module" do
    out = capture_io(fn -> assert Kazi.CLI.run(["schema", "portfolio"]) == 0 end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["command"] == "portfolio"
    assert payload["schema_version"] == Schema.schema_version()
    assert payload["example"]["schema_version"] == Schema.schema_version()
  end

  test "every documented field is actually emitted by a real portfolio --json result" do
    {:ok, schema} = Schema.fetch("portfolio")
    documented = schema.fields |> Enum.map(& &1.name) |> MapSet.new()

    out = capture_io(fn -> assert Kazi.CLI.run(["portfolio", "--json"]) == 0 end)
    decoded = Jason.decode!(String.trim(out))
    emitted = decoded |> Map.keys() |> MapSet.new()

    # No drift in either direction: the descriptor and the real portfolio_json/1
    # output name the exact same top-level keys.
    assert MapSet.equal?(documented, emitted),
           "schema/actual drift — documented only: #{inspect(MapSet.difference(documented, emitted))}, " <>
             "actual only: #{inspect(MapSet.difference(emitted, documented))}"
  end

  test "the example object in the descriptor is itself shaped like a real result" do
    {:ok, schema} = Schema.fetch("portfolio")
    example = schema.example

    assert example["kind"] == "portfolio"
    assert is_list(example["planned"])
    assert is_map(example["by_repo"])
    assert is_list(example["fleet_remote"])
    assert is_map(example["totals"])
    assert is_list(example["todo"])
    assert is_list(example["blocked"])
    assert is_map(example["rate"])
  end
end
