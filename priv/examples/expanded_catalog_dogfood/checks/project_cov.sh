#!/usr/bin/env bash
# Project-coverage grader for the :coverage provider's no-regression dimension
# (ADR-0043). Same metric as patch_cov.sh here (one module); kept separate so the
# project ratchet (project_baseline = "stored", may only improve) is exercised.
set -euo pipefail
exec "$(dirname "$0")/patch_cov.sh"
