# Kazi — Final With Refined Naming and Interface Composition

This scaffold re-renames and refines our design:

1. **Rename**:
   - `systemexec` → `runner`
   - `contextsource` → `memory`
   - `embeddb` → `db` sub-package of `memory`
   - `validation` → `validator`

2. **Break** aggregator into **small single-responsibility** interfaces (CodeSource, DocSource, LogSource, etc.) 
   with an optional aggregator that composes them.

3. **Interface-First** design remains, with each package:
   - `project/` holds domain, config, architecture, ephemeral logs, chunk references, progress in a single `Project`.
   - `memory/` holds small interfaces for code/doc/log retrieval, referencing an abstract DB in sub-package `db`.
   - `runner/` for whitelisted local commands.
   - `coordinator/` orchestrates LLM patch flow, referencing memory aggregator + runner + patch + validator.
   - `patch/` for minimal patch-based editing.
   - `validator/` for build/test checks.

We maintain SRP, OCP, DIP, concurrency, explicit errors, and doc clarity throughout.
