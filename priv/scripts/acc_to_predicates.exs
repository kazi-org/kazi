# T20.1 — the `acc:` → predicates BRIDGE runner (ADR-0026 L1).
#
# A thin, DETERMINISTIC, HERMETIC runner that turns a plan task's `acc:` line (the
# acceptance-criteria text of a `docs/plan.md` WBS task) into the caller-drafts
# predicates JSON payload `kazi propose --json --predicates` accepts. It does pure
# parsing only (Kazi.Pool.AccBridge.acc_to_predicates/1) and prints the JSON to
# stdout — no network, no clock, no DB. This is the FIRST half of the bridge; kazi
# does the second (apply the floor, persist, gate the merge on convergence).
#
# Usage (`--no-start` keeps stdout clean — the bridge is pure, no app boot needed):
#
#   # 1. Print the payload for an acc line:
#   mix run --no-start priv/scripts/acc_to_predicates.exs "ExUnit green; \`mix format\` clean; the endpoint returns 200"
#
#   # 2. Pipe it straight into kazi (caller-drafts; NO inner model is spawned):
#   mix run --no-start priv/scripts/acc_to_predicates.exs "ExUnit green; \`mix format\` clean" \
#     | kazi propose --json
#
#   # (`kazi propose --json` reads the piped payload from stdin under --json.)
#
# The acc text may also be supplied on stdin when no argument is given, e.g.:
#
#   grep -oP '(?<=acc: ).*' <task-line> | mix run --no-start priv/scripts/acc_to_predicates.exs
#
# See docs/acc-predicates-bridge.md for the full pool-session procedure.

acc =
  case System.argv() do
    [acc | _] -> acc
    [] -> IO.read(:stdio, :eof) |> to_string()
  end

acc
|> Kazi.Pool.AccBridge.acc_to_predicates()
|> Jason.encode!()
|> IO.puts()
