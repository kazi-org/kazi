# Kazi — Final "Interface-First" Design

This scaffold represents a **simpler yet powerful** approach to building the 
Kazi CLI tool for AI-driven development. We unify previously separate concepts 
(domain, config, doc logic) into a single **`project`** package. We also keep 
the **`lsp`** package for advanced code scanning and chunking. The rest of the 
system (coordinator, patch, validation) remains modular and easy to extend.

## Design Principles

1. **Single Responsibility**: Each package does *one* thing well:
   - `project`: Holds domain/vision details, blueprint architecture, and doc references.
   - `coordinator`: Orchestrates the prompt -> patch -> validation workflow.
   - `patch`: Minimal patch-based edits.
   - `validation`: Lint/tests/other checks as a pipeline.
   - `lsp`: Language Server Protocol integration (repo map, code scanning).
2. **Open-Closed**: You can add new types or methods without rewriting existing code.
3. **Liskov Substitution**: All interfaces are swappable with alternate implementations.
4. **Interface Segregation**: Many small, focused interfaces instead of one big “god” interface.
5. **Dependency Inversion**: The coordinator depends on abstract interfaces (`project.Manager`, `patch.Applier`, `validation.Pipeline`, etc.), not direct implementations.
6. **Composition Over Inheritance**: Each package composes or references smaller components, no heavy subclassing.
7. **Sharing Memory via Channels**: If concurrency is needed, we prefer channels/goroutines over global shared data.
8. **Explicit Errors**: No hidden exceptions; each method returns `error` if something can fail.
9. **Keep Packages Small**: Exactly what we do here. 
10. **Documented Code**: Each package has a README plus docstrings in `.go` files.

## Directory Layout

- `cmd/kazi/main.go`  
   Minimal CLI that parses arguments, dispatches subcommands (e.g., `kazi prompt ...`).  
- `internal/project/`  
   Merged domain + config + doc logic => a single `Project` struct capturing all.  
- `internal/coordinator/`  
   Runs the entire workflow from user prompt to patch to validation.  
- `internal/patch/`  
   Patch definitions, representing small code edits.  
- `internal/validation/`  
   Validation pipeline (lint, tests, security checks).  
- `internal/lsp/`  
   Tools for scanning code, building a “repo map,” chunking, or formatting.

**Happy building** with your new scaffold. 
