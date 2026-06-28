# Hero-cast demo (T25.2)

The smallest honest kazi reconcile run, used to record the convergence transcript
shown in the README and on the site home page (`assets/proof-loop.gif` /
`site/public/proof-loop.gif`, source cast `assets/proof-loop.cast`).

## What it is

- `workspace/` — a tiny Go module in its **broken** starting state: `Greet`
  returns the wrong word, so `go test` fails.
- `goal.toml` — one acceptance predicate (`custom_script`, `go test ./...`,
  `verdict = "exit_zero"`) that is `:fail` at t0 and `:pass` once the greeting is
  fixed.
- `record.sh` — runs `kazi apply` against a fresh copy of `workspace/` with the
  `claude` harness and de-noises the output (drops the Ecto/SQLite `:debug`
  lines, strips the timestamp prefix from `kazi.loop` lines). Every line it
  prints is verbatim kazi output.

## Reproduce the run

```sh
cp -r priv/examples/hero_cast_demo/workspace /tmp/hero-demo
kazi apply priv/examples/hero_cast_demo/goal.toml \
  --workspace /tmp/hero-demo --harness claude
```

kazi observes the failing predicate, dispatches the harness to fix `Greet`,
re-checks, and converges — `iter=1 failing=["tests-pass"]` → `iter=2 failing=[]`
→ `CONVERGED`.

## Re-record the cast / re-render the GIF

```sh
asciinema rec assets/proof-loop.cast \
  --output-format asciicast-v2 --overwrite --window-size 92x12 -i 2.0 \
  -c "KAZI=kazi $(pwd)/priv/examples/hero_cast_demo/record.sh"
agg --idle-time-limit 2 --font-size 16 assets/proof-loop.cast assets/proof-loop.gif
cp assets/proof-loop.gif site/public/proof-loop.gif
```

The committed `.cast` is the reproducible source of truth; the `.gif` is its
render (idle pauses capped at 2s so the real ~25s harness step stays watchable).
