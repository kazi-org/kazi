# `gherkin` provider — live acceptance fixture (T62.3, ADR-0071)

`storage-store.feature` is the executable storage-port contract from the **Sire**
project (sire.run): four Scenarios that a godog runner binds to a real SQLite
store. It is reproduced here VERBATIM (so scenario-name matching stays exact) as
the live acceptance fixture for the runtime `gherkin` predicate provider.

`storage-store.goal.toml` reconciles the feature NATIVELY into one verdict per
Scenario:

```
kazi apply priv/examples/gherkin/storage-store.goal.toml \
  --workspace priv/examples/gherkin --check --json
```

## Files

| File | Role |
|------|------|
| `storage-store.feature` | the contract (verbatim from the Sire project) |
| `storage-store.goal.toml` | the `provider = "gherkin"` goal — one verdict per Scenario |
| `storage-store.cucumber.json` | a CAPTURED real godog `--format=cucumber` run, replayed so CI needs no Go toolchain |
| `storage-store-replay.sh` | emits the captured report on stdout (the goal's runner) |
| `storage-store.broken.cucumber.json` | one scenario flipped to failed — the isolation fixture |
| `storage-store-broken-replay.sh` | replays the broken report |

The genuinely-live godog run (via `go test -overlay` over the Sire project's real
store, reusing its real step bindings — nothing written into that repo) is
recorded, with observed output, in `docs/devlog.md` (2026-07-18). CI keeps the
captured-replay proof: `test/kazi/goal/gherkin_sire_fixture_test.exs`.
