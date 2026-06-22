#!/usr/bin/env bash
# Stub that emulates a harness whose `--output-format json` output is MALFORMED
# (truncated / not valid JSON) — the degradation path for T4.1. The adapter must
# parse best-effort: fall back to the base result map (raw output + exit/command/
# workspace) and surface NO structured keys, never crashing. Like the other
# stubs this is a real external binary, not a lib/ stub.
set -euo pipefail

# Still write the workspace marker so the test can confirm the run happened.
echo "edited-by-stub" > stub_edit.txt

# Emit deliberately broken JSON (unterminated object, trailing garbage).
echo '{"type": "result", "usage": {"input_tokens": 100, oops not json'

exit "${STUB_EXIT:-0}"
