defmodule Kazi.CLIProjectTest do
  @moduledoc """
  T45.2 (UC-059): `kazi plan --project` — the caller-drafts roadmap flow end to
  end through the CLI, and its `kazi status <roadmap-ref> --json` read-back.
  HERMETIC: the read-model is the test SQLite Sandbox; no harness is spawned
  (caller-drafts).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp goal_entry(id, needs, integration_mode \\ nil) do
    base = %{
      "id" => id,
      "needs" => needs,
      "name" => id,
      "predicates" => [
        %{"id" => "#{id}-live", "provider" => "http_probe", "url" => "https://x.test/#{id}"}
      ]
    }

    if integration_mode,
      do: Map.put(base, "integration", %{"mode" => integration_mode}),
      else: base
  end

  test "plan --project persists a roadmap; status <roadmap-ref> reads its member proposals" do
    payload =
      Jason.encode!(%{
        "goals" => [
          goal_entry("foundation", []),
          goal_entry("api", ["foundation"], "pr"),
          goal_entry("ui", ["api"], "merge")
        ]
      })

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["plan", "--project", "--predicates", payload, "--json"]) == 0
      end)

    assert {:ok, result} = Jason.decode(String.trim(out))
    assert result["kind"] == "roadmap"
    assert result["roadmap_ref"] =~ ~r/^road-/
    assert length(result["proposals"]) == 3
    roadmap_ref = result["roadmap_ref"]

    # kazi status <roadmap-ref> --json resolves the roadmap to its member proposals.
    status_out =
      capture_io(fn ->
        assert Kazi.CLI.run(["status", roadmap_ref, "--json"]) == 0
      end)

    assert {:ok, status} = Jason.decode(String.trim(status_out))
    assert status["kind"] == "roadmap"
    assert status["roadmap_ref"] == roadmap_ref
    assert length(status["proposals"]) == 3

    assert Enum.map(status["proposals"], & &1["goal_id"]) |> Enum.sort() == [
             "api",
             "foundation",
             "ui"
           ]
  end

  test "plan --project surfaces the roadmap-unordered clarify for a needs-less pile" do
    payload = Jason.encode!(%{"goals" => [goal_entry("a", []), goal_entry("b", [])]})

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(["plan", "--project", "--predicates", payload, "--json"]) == 0
      end)

    assert {:ok, result} = Jason.decode(String.trim(out))
    assert Enum.any?(result["clarify"], &(&1["id"] == "roadmap-unordered"))
  end
end
