# Kazi — Interface-First Design

This scaffold provides a **complete interface-first** Kazi layout, 
adhering to the final design rules:

- Single Responsibility (SRP)
- Liskov Substitution
- Interface Segregation
- Dependency Inversion
- Composition over Inheritance
- Explicit error handling (no exceptions)
- Small packages with clear purpose
- Document code to clarify intent

Below are the packages:

1. `cmd/kazi/` — The CLI entry point with subcommands (init, build, deploy, prompt).
2. `internal/project/` — Domain/config data stored in a `Project`.
3. `internal/memory/` — Code/doc/log retrieval. Sub-package `db` for an embedded vector DB interface.
4. `internal/runner/` — Whitelisted local command runner.
5. `internal/coordinator/` — The main AI-driven prompt -> patch -> validation orchestrator.
6. `internal/patch/` — Minimal patch-based editing.
7. `internal/validator/` — Pipeline for build/test or security checks.

