#!/usr/bin/env bash
# Replay of a godog run where ONE scenario fails — proves the gherkin provider
# reds only that scenario's sub-predicate (T62.3 isolation proof).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat "${here}/storage-store.broken.cucumber.json"
