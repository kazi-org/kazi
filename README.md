# Kazi (Version 2)

This directory demonstrates the **Version 2** design for the Kazi AI-driven 
software development tool. It merges the "vision contract" (product constraints) 
with operational config, minimal patch-based editing, and a single coordinator 
flow for orchestrating code generation and validation.

**Structure Overview**:

- `cmd/kazi/`: CLI entry point (e.g., `main.go`).
- `internal/vision/`: Manages the Vision Contract logic.
- `internal/architecture/`: Manages the high-level blueprint (interfaces) and code chunking.
- `internal/coordinator/`: Orchestrates each generation cycle with the LLM (prompt -> patch -> validation).
- `internal/patch/`: Minimal patch-based code editing logic.
- `internal/validation/`: Runs lint/tests/other checks in one pipeline.
- `internal/knowledge/`: Logs patch successes/failures or historical data.
- `internal/config/`: Loads Kubernetes-style manifests or direct config for workspace/commands.
- `internal/lsp/`: Optional integration with a Language Server Protocol client or similar.

Read each package's README for more details.
