# T13.6 — E13 intended-vs-actual reconciliation dogfood (ADR-0021).
#
# A throwaway, reproducible USAGE script (not a test): it exercises the done E13
# modules and prints the findings recorded in docs/devlog.md (2026-06-24). It
# changes nothing and reads no network/clock.
#
#   mix run priv/scripts/t13_6_dogfood.exs
#
# Part 1 — scan kazi's OWN lib surface with Kazi.Reconcile.SurfaceScanner, then
#          run the Kazi.Reconcile.Coverage meta-predicate against a representative
#          kazi goal's intended predicates, reporting kazi's own A \ I.
# Part 2 — demonstrate Kazi.Reconcile.OpenApiImporter on the committed T13.1
#          fixture -> grouped http_probe acceptance predicates.
#
# NOTE (honest limitation, see devlog): the original "dogfood an external service"
# target is a GO codebase and the scanner is Elixir-only, so the scan half runs on
# kazi itself here. Follow-ups: a Go scanner, ingest the service's YAML OpenAPI
# (JSON-only today), or the prose importer over the service's ADRs.

alias Kazi.Reconcile.{SurfaceScanner, Coverage, OpenApiImporter}

workspace = File.cwd!()

# --- Part 1: scan kazi itself + coverage vs a representative goal --------------

surface = SurfaceScanner.scan(workspace)

IO.puts("=== Part 1: surface scan (A) of kazi's own lib/ ===")
IO.puts("total elements: #{length(surface)}")
surface |> Enum.frequencies_by(& &1.kind) |> IO.inspect(label: "by kind")

{:ok, goal} = Kazi.Goal.Loader.load("priv/goals/e3-t3.4-standing-reconciler.toml")
predicates = goal.predicates ++ goal.guards

IO.puts("\nintended set (I) from goal #{inspect(goal.id)}:")
Enum.each(predicates, fn p -> IO.puts("  #{p.id} (#{p.kind}) cfg=#{inspect(p.config)}") end)

result = Coverage.check(surface, predicates)

IO.puts("\ncoverage result:")
IO.puts("  status:           #{result.status}")
IO.puts("  owned:            #{length(result.owned)}")
IO.puts("  allowed:          #{length(result.allowed)}")
IO.puts("  unowned (A \\ I):  #{length(result.unowned)}")

IO.puts("\nsample unowned (candidate dead/undocumented surface):")

result.unowned
|> Enum.take(10)
|> Enum.each(fn e -> IO.puts("  [#{e.kind}] #{e.identifier}  (#{e.path}:#{e.line})") end)

IO.puts("\nowned (note: matcher is approximate — these may be spurious substring hits):")
Enum.each(result.owned, fn e -> IO.puts("  [#{e.kind}] #{e.identifier}") end)

IO.puts("\nunowned by top-level module (top 10):")

result.unowned
|> Enum.map(fn e -> e.identifier |> String.split(".") |> Enum.take(2) |> Enum.join(".") end)
|> Enum.frequencies()
|> Enum.sort_by(fn {_m, n} -> -n end)
|> Enum.take(10)
|> Enum.each(fn {m, n} -> IO.puts("  #{n}\t#{m}") end)

# --- Part 2: OpenApiImporter demonstration ------------------------------------

IO.puts("\n=== Part 2: OpenApiImporter on the T13.1 petstore fixture ===")
json = File.read!("test/fixtures/reconcile/petstore.openapi.json")
{:ok, map} = OpenApiImporter.import_map(json)

IO.puts("goal: id=#{map["id"]} name=#{inspect(map["name"])} mode=#{map["mode"]}")
IO.puts("groups: #{map["group"] |> Enum.map(& &1["id"]) |> Enum.join(", ")}")
IO.puts("predicates (#{length(map["predicate"])}):")

Enum.each(map["predicate"], fn p ->
  IO.puts("  #{p["id"]}\t[#{p["group"]}]\t#{p["method"]} #{p["path"]} -> #{p["expect_status"]}")
end)

{:ok, imported} = OpenApiImporter.import_goal(json)

IO.puts(
  "round-trips to %Kazi.Goal{}: mode=#{imported.mode} " <>
    "predicates=#{length(imported.predicates)} groups=#{length(imported.groups)}"
)
