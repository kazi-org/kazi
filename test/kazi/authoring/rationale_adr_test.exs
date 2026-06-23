defmodule Kazi.Authoring.RationaleAdrTest do
  @moduledoc """
  T11.7 (UC-029, ADR-0019): `kazi propose --adr` renders a proposed goal into an
  ADR-lite markdown file at the next sequence number, idempotent per proposal_ref.
  Writes to a tmp dir; no real `docs/adr/` is touched.
  """
  use ExUnit.Case, async: true

  alias Kazi.Authoring.{Draft, RationaleAdr}
  alias Kazi.{Goal, Predicate}

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-adr-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp draft(opts \\ []) do
    ref = Keyword.get(opts, :ref, "prop-healthz-abc123")

    rationale =
      Keyword.get(opts, :rationale, "probe the deployed endpoint; tests-only is out of scope")

    goal =
      Goal.new("healthz-endpoint",
        name: "Health endpoint returns 200",
        mode: :create,
        predicates: [
          Predicate.new(:health, :http_probe,
            description: "GET /healthz returns 200",
            acceptance?: true
          )
        ],
        metadata: %{"rationale" => rationale}
      )

    %Draft{proposal_ref: ref, idea: "a /healthz endpoint", status: :proposed, goal: goal}
  end

  test "writes a well-formed ADR-lite file at the next number", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "0007-existing.md"), "# ADR 0007\n")

    assert {:ok, path} = RationaleAdr.write(draft(), dir: dir, date: ~D[2026-06-23])
    assert Path.basename(path) == "0008-healthz-endpoint.md"

    content = File.read!(path)
    assert content =~ "# ADR 0008: Goal proposal -- Health endpoint returns 200"
    assert content =~ "## Status\nProposed"
    assert content =~ "2026-06-23"
    assert content =~ "> a /healthz endpoint"
    assert content =~ "`prop-healthz-abc123`"
    assert content =~ "- `health` (http_probe): GET /healthz returns 200"
    assert content =~ "tests-only is out of scope"
  end

  test "allocates 0001 in an empty directory", %{dir: dir} do
    assert {:ok, path} = RationaleAdr.write(draft(), dir: dir, date: ~D[2026-06-23])
    assert Path.basename(path) == "0001-healthz-endpoint.md"
  end

  test "is idempotent for the same proposal_ref -- rewrites in place", %{dir: dir} do
    assert {:ok, path1} =
             RationaleAdr.write(draft(rationale: "v1"), dir: dir, date: ~D[2026-06-23])

    assert {:ok, path2} =
             RationaleAdr.write(draft(rationale: "v2"), dir: dir, date: ~D[2026-06-23])

    assert path1 == path2
    assert length(Path.wildcard(Path.join(dir, "*.md"))) == 1
    assert File.read!(path2) =~ "v2"
  end

  test "falls back to a default line when no rationale was recorded", %{dir: dir} do
    no_rationale = %Draft{draft() | goal: %Goal{draft().goal | metadata: %{}}}
    assert {:ok, path} = RationaleAdr.write(no_rationale, dir: dir, date: ~D[2026-06-23])
    assert File.read!(path) =~ "No rationale was recorded"
  end
end
