## Table of Contents

1. [Overview](#overview)
2. [Packages & Responsibilities](#packages--responsibilities)
3. [Interface-First Approach](#interface-first-approach)
4. [Embedded DB Strategy](#embedded-db-strategy)
5. [Detailed Rationale](#detailed-rationale)
    - [Single Responsibility Principle (SRP)](#single-responsibility-principle-srp)
    - [Open-Closed Principle (OCP)](#open-closed-principle-ocp)
    - [Liskov Substitution Principle (LSP)](#liskov-substitution-principle-lsp)
    - [Interface Segregation Principle (ISP)](#interface-segregation-principle-isp)
    - [Dependency Inversion Principle (DIP)](#dependency-inversion-principle-dip)
    - [Composition over Inheritance](#composition-over-inheritance)
    - [Concurrency & Explicit Errors](#concurrency--explicit-errors)
    - [Small Packages & Documentation](#small-packages--documentation)
6. [Conclusion](#conclusion)

---

## 1. Overview

**Kazi** is an AI-driven development tool that integrates Large Language Models (LLMs), patch-based editing, validation pipelines, and local or remote commands. This final design:

- **Unifies** data about the project (domain constraints, config, architecture, ephemeral logs, chunk references, progress) in a **single `Project` struct**.
- **Leverages** a **vector/embeddings DB** (like [chromem-go](https://github.com/philippgille/chromem-go)) behind an **abstract interface** to store and retrieve relevant text or code context for the LLM.
- **Provides** a **whitelisted command runner** so the LLM can safely request local commands if needed.
- **Keeps** a minimal patch-based approach (`PatchSet`) and a `Validator` pipeline for build/test checks.
- **Follows** interface-first design, with each package focusing on a single concern.

---

## 2. Packages & Responsibilities

### `cmd/kazi/`
- **Purpose**: The CLI entry point with subcommands (`init`, `build`, `deploy`, `prompt`).  
- **Responsibility**: Minimal argument parsing, then delegates to higher-level logic (coordinator, project manager, etc.).

### `internal/project/`
- **Contains** a single `Project` struct (merging domain, architecture, config, ephemeral logs, chunk references, progress).  
- **`ProjectManager`** loads/saves the project from a YAML or other sources.

### `internal/memory/`
- **Renamed** from `contextsource`.  
- **Defines** specialized interfaces: `CodeSource`, `DocSource`, `LogSource`.  
- **`MemoryAggregator`** composes them for an all-in-one retrieval approach if desired.

#### `internal/memory/db/`
- **Renamed** from `embeddb`.  
- **Stores** a simple `DB` interface for an embedded vector database, e.g. [chromem-go](https://github.com/philippgille/chromem-go).  
- **Methods**: `StoreText` and `QueryText` returning top-K results by similarity. 
- This ensures we can swap out the DB with another library if needed.

### `internal/runner/`
- **Renamed** from `systemexec`.  
- **Defines** a `ExecRunner` interface for whitelisted local commands (like `grep`, `ls`).  
- Helps the LLM or coordinator gather local info in a controlled environment.

### `internal/patch/`
- **Holds** minimal patch-based editing logic:
  - `PatchSet` with a subject (LLM instructions) plus small line-based or file-based changes.
  - `Applier` interface to apply the changes.

### `internal/validator/`
- **Renamed** from `validation`.  
- **Defines** a `Pipeline` for build/test checks. 
- Example: concurrency-based lint/test steps, returning a `ValidationResult`.

### `internal/coordinator/`
- **Houses** the main orchestration logic:
  - `Coordinator` references:
    - LLM-based patch generation (`PatchGenerator`).
    - The aggregator from `memory` for code/docs/log context retrieval.
    - The whitelisted `runner` for local command execution.
    - Patch application plus `validator` pipeline for final checks.
- **Implements** a single `ProcessPrompt` method that ties everything together.

---

## 3. Interface-First Approach

We ensure each package **exposes small, stable interfaces** instead of large monolithic ones:

- `PatchGenerator`, `PatchApplier`, `Pipeline`, `ExecRunner`, `CodeSource`, `DocSource`, `LogSource`, `DB`, etc.
- **Coordinator** references them, but is not tightly coupled to any specific implementation.  
- This fosters **extension** without rewriting existing code.

---

## 4. Embedded DB Strategy

We place an **abstract `DB` interface** in `internal/memory/db`.  
Why?

1. **We want** to store code, docs, logs, or other textual data for **similarity search** (like RAG).  
2. **We can** implement it using [chromem-go](https://github.com/philippgille/chromem-go) or any other embedding-based approach.  
3. **If** we want to switch to a different vector store, we only replace the `DB` implementation. The rest of Kazi doesn’t change.

---

## 5. Detailed Rationale

### Single Responsibility Principle (SRP)

- Each package addresses **one** concern:  
  - `project` for storing domain/config data,  
  - `memory` for code/doc/log retrieval,  
  - `runner` for local commands,  
  - `patch` for small code edits,  
  - `validator` for build/test checks,  
  - `coordinator` orchestrating LLM flows.

### Open-Closed Principle (OCP)

- We can **extend** with new subcommands, new data sources, new patch logic, or a new build pipeline **without** modifying existing, stable interfaces. For example, we can add a `MetricSource` or an `ANNDB` behind the same `DB` interface, or a new check in the `validator` pipeline.

### Liskov Substitution Principle (LSP)

- Any new or replaced implementation (like a different embedded DB) can fulfill the same interface (like `DB`) and not break the rest of the system. For example, we can swap from `chromem-go` to a custom vector library.

### Interface Segregation Principle (ISP)

- In `memory`, we separate `CodeSource`, `DocSource`, `LogSource` so each interface is small, doing **exactly** one job.  
- An aggregator composes them if we want an “all-in-one” approach, which is also small and minimal.

### Dependency Inversion Principle (DIP)

- The coordinator depends on abstract interfaces (`PatchGenerator`, `MemoryAggregator`, `ExecRunner`, `patch.Applier`, `validator.Pipeline`), **not** on direct concretions.  
- `memory/db` is also an interface, so we can easily replace the vector storage.

### Composition Over Inheritance

- We embed references to aggregator or runner rather than using inheritance or big class hierarchies.  
- `MemoryAggregator` composes `CodeSource`, `DocSource`, `LogSource`.

### Concurrency & Explicit Errors

- Where concurrency is beneficial (like in `DefaultProjectManager` or the aggregator), we can spawn goroutines or use channels. We do not share memory globally but pass data via function calls or channels.  
- All possible errors are returned explicitly (`error`) instead of hidden or using exceptions.

### Small Packages & Documentation

- Each package is **small** and **targeted**.  
- We place short README files clarifying each package’s scope and docstrings on each interface or struct.  
- This fosters easy navigation and comprehension.

---

## 6. Conclusion

This **final design** ensures:

1. **A Single, Clear `Project`** struct for all project data (domain, architecture, config, ephemeral logs, chunk references, progress).  
2. **Memory** with **small specialized interfaces** (code/doc/log) and an aggregator for code retrieval.  
3. **`db`** sub-package for an **embedded vector store** behind an interface, enabling RAG or semantic search using something like `chromem-go`.  
4. **`runner`** for whitelisted local commands.  
5. **`patch`** and **`validator`** for code edits and build/test checks.  
6. A **coordinator** that ties everything together under an AI-based prompt->patch->validate flow.  
7. **Interface-First**—the system is easy to test, extend, and maintain.
