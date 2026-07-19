#!/usr/bin/env bash
# CI-safe replay of a REAL godog `--format=cucumber` run of storage-store.feature
# (captured from the Sire project's storage port contract). Emits the cucumber-json
# array on stdout so the `gherkin` provider ingests per-scenario verdicts without a
# Go toolchain in CI. The live godog proof is recorded in docs/devlog.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat "${here}/storage-store.cucumber.json"
