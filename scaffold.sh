#!/usr/bin/env bash
#
# bootstrap_kazi.sh
#
# Creates a final "interface-first" design for kazi, merging:
# - domain/vision + config + doc logic => internal/project
# - lsp package for code scanning (repo map, chunking, etc.)
# - patch, coordinator, validation remain separate but smaller
# - Enough docstrings and READMEs to guide new developers
#
# Usage:
#   ./bootstrap_kazi.sh <PROJECT_DIR>
#
# Example:
#   ./bootstrap_kazi.sh kazi-final

set -euo pipefail

PROJECT_DIR="${1:-kazi-project}"

echo "Creating Kazi final scaffold in: $PROJECT_DIR"

###############################################################################
# 1) CREATE DIRECTORIES
###############################################################################
mkdir -p "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/cmd/kazi"
mkdir -p "$PROJECT_DIR/internal"
mkdir -p "$PROJECT_DIR/internal/project"
mkdir -p "$PROJECT_DIR/internal/coordinator"
mkdir -p "$PROJECT_DIR/internal/patch"
mkdir -p "$PROJECT_DIR/internal/validation"
mkdir -p "$PROJECT_DIR/internal/lsp"

###############################################################################
# 2) TOP-LEVEL README
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/README.md"
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
EOF

###############################################################################
# 3) CMD/kazi/main.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/cmd/kazi/main.go"
// Package main provides the CLI entry point for Kazi.
// In a real application, you'd parse subcommands (like "prompt") and
// initialize core components (project, coordinator, etc.).

package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: kazi <command> [args]")
		os.Exit(1)
	}

	subcommand := os.Args[1]
	switch subcommand {
	case "prompt":
		// Example: kazi prompt "Implement feature X"
		fmt.Println("Prompt subcommand not implemented. See coordinator logic.")
	default:
		fmt.Printf("Unknown subcommand: %s\n", subcommand)
	}
}
EOF

###############################################################################
# 4) internal/project/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/project/README.md"
# project

The **project** package merges domain/vision details, operational config,
and optional doc (memory) references into a **single** cohesive model.

## Key Responsibilities

1. **Domain Contract** (Name, Description, Constraints)
2. **Architecture** (modules, interfaces)
3. **Config** (lint/test commands, workspace)
4. **Doc-Related** (optional references to doc files or user instructions)

By merging these, we avoid scattering "vision" vs. "config" vs. "blueprint" 
across multiple packages, simplifying developer mental load.

## Typical Flow

- The `Manager` interface can `LoadProject` from a YAML file or other source,
  returning a single `Project` struct that includes domain constraints, architecture,
  and config in one place.
- `coordinator` then queries `project` for data to feed the LLM or chunk code.
- If you want to store doc files or ephemeral logs, you can incorporate them 
  directly or reference separate logic.

EOF

###############################################################################
# 5) internal/project/project.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/project/project.go"
// Package project merges domain constraints (vision), blueprint architecture,
// and config into a single "Project" model. This drastically reduces duplication
// while still allowing a structured interface-first design.

package project

// Project holds the entire "big picture" of what we're building.
type Project struct {
	// Domain-level info (Vision Contract)
	Name        string
	Description string
	Constraints map[string]string

	// Architecture-level info (modules & interfaces)
	Modules []ModuleSpec

	// Config-level info for workspace, commands, etc.
	Workspace   string
	LintCommand string
	TestCommand string

	// (Optional) If you want doc references or ephemeral logs,
	// you could add fields here like "DocsPath", or "RecentPatchSummaries", etc.
}

// ModuleSpec describes a subsystem or module in the architecture.
type ModuleSpec struct {
	Name       string
	Interfaces []InterfaceSpec
}

// InterfaceSpec defines an interface's name and method signatures.
type InterfaceSpec struct {
	Name    string
	Methods []MethodSig
}

// MethodSig holds a single method's name, parameters, return types.
type MethodSig struct {
	Name       string
	Parameters []string
	Returns    []string
}

// Manager defines how to load/update a Project from external sources (YAML, etc.),
// and optionally handle chunking or doc references if needed.
type Manager interface {
	// LoadProject loads the entire Project object (domain + architecture + config).
	LoadProject(pathOrData string) (*Project, error)

	// ProvideChunks optionally returns code or file segments relevant
	// to a module or file, for LLM context. This can be backed by an LSP
	// or simple file reading. 
	ProvideChunks(moduleOrFile string, maxTokens int) ([]string, error)
}
EOF

###############################################################################
# 6) internal/coordinator/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/coordinator/README.md"
# coordinator

Orchestrates the "prompt -> LLM -> patch -> validation" cycle. 

## Key Steps

1. **Load/Update Project**: The coordinator queries `project.Manager` to get 
   or update the full system context (domain constraints, architecture, config).
2. **LLM Prompt**: Summarizes the Project and relevant code chunks (via `ProvideChunks`) 
   for the LLM to generate a patch.
3. **Patch Application**: Calls `patch.Applier` to apply the minimal changes.
4. **Validation**: Invokes `validation.Pipeline` to ensure code quality. 
   If success, commit or finalize. If failure, revert or prompt user.

EOF

###############################################################################
# 7) internal/coordinator/coordinator.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/coordinator/coordinator.go"
// Package coordinator provides a single interface that orchestrates
// the entire workflow from user prompt to final validated code changes.

package coordinator

import (
	"github.com/yourorg/kazi/internal/patch"
	"github.com/yourorg/kazi/internal/project"
	"github.com/yourorg/kazi/internal/validation"
)

// Coordinator orchestrates the prompt -> LLM -> patch -> validation loop.
type Coordinator interface {
	// ProcessPrompt is the main workflow:
	//  1. Load/Update project context
	//  2. Generate a patch from the LLM
	//  3. Apply the patch
	//  4. Validate
	//  5. Commit or revert
	ProcessPrompt(prompt string) error
}

// DefaultCoordinator is a reference implementation that composes
// a Project Manager, Patch Applier, and Validation Pipeline.
// We also may reference an LSP client or knowledge logs if needed.
type DefaultCoordinator struct {
	ProjectManager project.Manager
	PatchApplier   patch.Applier
	Validator      validation.Pipeline
	// Possibly: LLM client, doc store, ephemeral logs, etc.
}

// ProcessPrompt is a stub to illustrate how you'd orchestrate the workflow.
func (dc *DefaultCoordinator) ProcessPrompt(prompt string) error {
	// 1. Retrieve or update the project (dc.ProjectManager.LoadProject(...) if needed)
	// 2. Possibly retrieve code chunks via ProvideChunks(...)
	// 3. Call LLM with the project + chunk info => get patch
	// 4. dc.PatchApplier.Apply(patchSet)
	// 5. dc.Validator.ValidateAll()
	// 6. If success, commit or finalize. If fail, revert or ask user.
	return nil
}
EOF

###############################################################################
# 8) internal/patch/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/patch/README.md"
# patch

Handles minimal patch-based editing. The LLM outputs a PatchSet specifying
where to create, replace, or delete lines in the codebase. The patch logic
ensures small, targeted edits, reducing hallucination risk.

EOF

###############################################################################
# 9) internal/patch/patch.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/patch/patch.go"
// Package patch defines the data structures and interfaces for minimal
// patch-based code edits.

package patch

// PatchSet groups one or more patch operations with an optional subject message.
type PatchSet struct {
	Subject string
	Patches []PatchOperation
}

// PatchOperation is a single file change: create, replace, or delete lines.
type PatchOperation struct {
	File        string
	Type        string // "create", "replace", "delete"
	FromLine    int
	ToLine      int
	Content     string
	LinesBefore []string
	LinesAfter  []string
}

// Applier applies patch sets to a local filesystem or code repo.
type Applier interface {
	Apply(ps *PatchSet) error
}
EOF

###############################################################################
# 10) internal/validation/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/validation/README.md"
# validation

Defines a single pipeline that runs various checks (lint, tests, security, etc.) 
to confirm a patch is correct and production-ready.

EOF

###############################################################################
# 11) internal/validation/validation.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/validation/validation.go"
// Package validation supplies a Pipeline interface that runs multiple checks
// on the codebase, ensuring it meets quality standards before final acceptance.

package validation

// Pipeline runs a sequence of checks, returning an error if any fail.
type Pipeline interface {
	ValidateAll() error
}

// DefaultPipeline is a reference implementation that might store shell commands
// for lint/test, then run them in ValidateAll().
type DefaultPipeline struct {
	LintCommand string
	TestCommand string
}

func (p *DefaultPipeline) ValidateAll() error {
	// e.g., run lint (p.LintCommand), run tests (p.TestCommand), gather errors
	return nil
}
EOF

###############################################################################
# 12) internal/lsp/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/lsp/README.md"
# lsp

Provides Language Server Protocol (LSP) integration or any code-analysis 
services that help the LLM or user. For instance, you can use the LSP 
to build a "repo map", chunk the code for the LLM, perform symbol queries, etc.

## Example Usage

- Summon `AnalyzeFile` to find issues or gather line references.
- `FormatCode` for consistent style before/after patching.
- Possibly store an internal "repo map" of all files/lines to feed the LLM 
  in smaller chunks.

EOF

###############################################################################
# 13) internal/lsp/lsp.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/lsp/lsp.go"
// Package lsp defines a minimal interface for a Language Server Protocol or
// equivalent code analysis service, enabling advanced scanning, chunking, or formatting.

package lsp

// Issue represents a single code warning/error from the LSP.
type Issue struct {
	Severity string
	Message  string
	Line     int
	Column   int
}

// Client allows basic code analysis and formatting. 
// In a real system, you might expand this to handle references, symbol queries, etc.
type Client interface {
	FormatCode(filePath string) (string, error)
	AnalyzeFile(filePath string) ([]Issue, error)
}
EOF

echo "Scaffold created successfully in $PROJECT_DIR!"
echo "----------------------------------------------"
echo "You can now explore the following packages:"
echo "  - cmd/kazi         (CLI entry point)"
echo "  - internal/project (Merged domain/config/docs concept)"
echo "  - internal/coordinator"
echo "  - internal/patch"
echo "  - internal/validation"
echo "  - internal/lsp"
echo "Use this scaffold to implement your AI-driven dev workflow. Enjoy!"
