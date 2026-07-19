# The `visual_judge` predicate

`visual_judge` is kazi's **pinned strong-model screenshot judgment** (T68.8,
#1522): it judges what deterministic visual checks cannot — hierarchy, restraint,
fidelity to an approved design's structure — while **keeping objective
termination**. It sends a controller-owned screenshot, an optional design
reference, and a fixed **rubric** to a pinned model and gates on the model's
**itemized** pass/fail verdict. The critique is the red detail: each violated
rubric criterion reaches the worker as actionable feedback for the next reconcile
iteration.

It is **not** a "beauty score." A scalar invites threshold-shopping and cannot
converge; `visual_judge` converges on itemized pass/fail against a pinned model +
a content-hashed rubric + fixed decode settings (temperature 0) — as reproducible
as any external-tool predicate.

This is the judgment layer over the capture machinery of
[ADR-0081](adr/0081-capture-recipes-run-evidence-store.md); it consumes the SAME
controller-produced capture that [`render_proof`](capture-recipes.md) does.
`render_proof` gates that the UI actually *rendered*; `visual_judge` gates that
what rendered is *right*.

## What it judges — and never sees

The judge model receives ONLY pixels + the author's rubric:

- **screenshot** — a controller-produced capture (`[[capture]]`, ADR-0081),
  resolved from `context[:captures]` by name — never a workspace path the worker
  chose, so a cached/forged build cannot answer for current code.
- **reference image(s)** — optional approved mockup crops, read from the
  workspace.
- **rubric** — a fixed list of pass/fail criteria authored at plan time.

It never reads workspace **source text**, so a converging worker cannot
prompt-inject the judge through code or comments.

## Tamper-evidence (seal)

The rubric and pinned `model` live in the goal-file, which is **implicitly
sealed** ([ADR-0080](adr/0080-sealed-predicates-tamper-detection.md)). Reference
images should be declared under `[seal] sealed_inputs`. A worker that loosens the
rubric or swaps the reference mid-run flips the run **`tampered`** — never green.

## Config

| Key | Required | Meaning |
|---|---|---|
| `capture` | yes | The capture name to judge (the screenshot). Equivalently `input = "capture:<name>"`. |
| `rubric` | yes | A non-empty list of criterion strings — the pass/fail checklist. |
| `model` | yes | The pinned judge model id, recorded (and sealed) in the goal-file. |
| `reference` | no | Workspace-relative path (or list of paths) to reference image(s). Declare under `[seal] sealed_inputs`. |
| `votes` | no | N-vote majority sample count for stability (default `1`), passed to the model transport. |

```toml
[[capture]]
name = "now_screen"
launch_cmd = "node"
launch_args = ["scripts/screenshot.js", "--route", "/now"]
output = "now_screen.png"

[seal]
sealed_inputs = ["checks/reference/now.png"]

[[predicate]]
id = "now-screen-looks-right"
provider = "visual_judge"
capture = "now_screen"
model = "claude-opus-4-8"
reference = "checks/reference/now.png"
votes = 3
rubric = [
  "no stock tab bar; a raised circular center control is present",
  "the primary CTA is visually dominant",
  "no body text below 4.5:1 contrast",
]
```

## Verdict mapping (honest verdicts, ADR-0002)

| Status | When |
|---|---|
| `:pass` | The model returned `pass: true`. |
| `:fail` | The model returned `pass: false`. The itemized `failures` (`criterion` + `observation`) ride in the evidence as the critique — real failing work the worker fixes. |
| `:unknown` | The judge could not reach a verdict from valid inputs: the capture is missing / failed / unreadable, a reference is unreadable, the model call failed, or its response was unparseable. **Red, never green** — a capture the loop never produced cannot pass. |
| `:error` | Provider misconfiguration or unwired infra: no `capture` / `rubric` / `model`, or **no model transport wired** (`:model_not_configured`). Not failing work, so it does not dispatch a fixer. |

## The model transport is an injectable seam

The provider does not embed a concrete multimodal API client. It resolves the
transport from application env:

```elixir
config :kazi, :visual_judge_model, MyApp.VisualJudgeModel
```

The module implements `Kazi.Providers.VisualJudge.Model` — a single
`judge(request) :: {:ok, %{pass, failures}} | {:error, reason}` callback that
selects the pinned `model` id per request and (optionally) runs the `votes`
majority. The default `Kazi.Providers.VisualJudge.UnconfiguredModel` returns
`{:error, :model_not_configured}`, so a `visual_judge` predicate on a deployment
that never wired a transport fails **loud** (`:error`), never green. A real
API-backed transport is out of hermetic scope (the same posture ADR-0081 takes
for live capture); the provider's mapping is pinned in tests with a recorded
verdict, no live API.

## Scheduling (staging) — a note

`visual_judge` is expensive (a strong-model call), so it is intended to be
*staged*: evaluated only once the cheaper predicates in the vector are green, and
bounded so a run that cannot satisfy the judge parks for a human rather than
looping the model forever. That loop-scheduler behaviour is tracked as follow-up
work; this provider ships the judgment + honest verdicts + tamper-evident bar.
