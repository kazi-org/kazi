#!/usr/bin/env bash
#
# bootstrap_kazi_interfaces.sh
#
# Creates a final Kazi scaffold with an interface-first design that strictly follows:
# - Single Responsibility per type
# - Liskov Substitution
# - Interface Segregation
# - Dependency Inversion
# - Composition over inheritance
# - Explicit error handling
# - Small, focused packages
# - Clear package-level README docs
#
# Usage:
#   ./bootstrap_kazi_interfaces.sh <PROJECT_DIR>
#

set -euo pipefail

PROJECT_DIR="${1:-kazi-final}"

echo "Creating final interface-first Kazi structure in: $PROJECT_DIR"

###############################################################################
# 1) CREATE DIRECTORY STRUCTURE
###############################################################################
mkdir -p "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/cmd/kazi"
mkdir -p "$PROJECT_DIR/internal"
mkdir -p "$PROJECT_DIR/internal/project"
mkdir -p "$PROJECT_DIR/internal/memory"
mkdir -p "$PROJECT_DIR/internal/memory/db"
mkdir -p "$PROJECT_DIR/internal/runner"
mkdir -p "$PROJECT_DIR/internal/coordinator"
mkdir -p "$PROJECT_DIR/internal/patch"
mkdir -p "$PROJECT_DIR/internal/validator"

###############################################################################
# 2) TOP-LEVEL README
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/README.md"
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

EOF

###############################################################################
# 3) cmd/kazi/main.go + README
###############################################################################
mkdir -p "$PROJECT_DIR/cmd/kazi"
cat <<'EOF' > "$PROJECT_DIR/cmd/kazi/README.md"
# cmd/kazi

**Purpose**: Provide a CLI subcommand structure for Kazi:
- `kazi init` 
- `kazi build`
- `kazi deploy`
- `kazi prompt "..."`

**Single Responsibility**: 
- Only parse CLI arguments and delegate to internal packages.

## Implementation

- Read subcommand from `os.Args[1]`.
- For “init,” you might call `project.DefaultProjectManager`.
- For “prompt,” create a coordinator with your specialized LLM and run `ProcessPrompt`.
- For “build,” call `validator.Pipeline` or other logic.
- For “deploy,” integrate a deployment approach.

EOF

cat <<'EOF' > "$PROJECT_DIR/cmd/kazi/main.go"
// Package main provides the CLI entry point for Kazi.
// Subcommands: init, build, deploy, prompt "..."
//
// Single responsibility: parse arguments, route subcommands to internal logic.
package main

import (
	"fmt"
	"os"
)

func usage() {
	fmt.Println(`kazi - usage:
  kazi init
  kazi build
  kazi deploy
  kazi prompt "Implement X"
`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	subcommand := os.Args[1]
	switch subcommand {
	case "init":
		fmt.Println("[INIT] placeholder logic, calls project manager or doc references")
	case "build":
		fmt.Println("[BUILD] placeholder logic, calls validator pipeline")
	case "deploy":
		fmt.Println("[DEPLOY] placeholder logic, integrate deployment approach")
	case "prompt":
		fmt.Println("[PROMPT] placeholder logic, orchestrates AI-driven patch flow")
	default:
		fmt.Printf("Unknown subcommand: %s\n", subcommand)
		usage()
	}
}
EOF

###############################################################################
# 4) internal/project/PROJECT
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/project/README.md"
# internal/project

Stores domain/config data in a single **Project** struct. 
Provides a **ProjectManager** interface to load/save or manipulate the project.

## Single Responsibility

- Only track project data (domain constraints, architecture, ephemeral logs, chunk references, progress).
- Avoid embedding advanced logic (like LLM calls or patch steps).

## Implementation Tips

- The default manager might use a YAML file ".kazi.yaml".
- A developer can write a custom manager that loads from multiple files or a DB.

EOF

cat <<'EOF' > "$PROJECT_DIR/internal/project/project.go"
package project

import (
	"context"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Project merges domain constraints, config, architecture, ephemeral logs, chunk references, progress.
type Project struct {
	Name        string
	Description string
	Constraints map[string]string

	Modules []ModuleSpec

	Workspace   string
	LintCommand string
	TestCommand string

	Logs            []string
	ChunkReferences map[string]string

	Progress ProgressState
}

type ModuleSpec struct {
	Name       string
	Interfaces []InterfaceSpec
}

type InterfaceSpec struct {
	Name    string
	Methods []MethodSig
}

type MethodSig struct {
	Name       string
	Parameters []string
	Returns    []string
}

type ProgressState struct {
	Steps map[string]ProgressStatus
}

type ProgressStatus string

const (
	NotStarted ProgressStatus = "not-started"
	InProgress ProgressStatus = "in-progress"
	Completed  ProgressStatus = "completed"
)

func (ps *ProgressState) MarkStep(stepName string, status ProgressStatus) {
	if ps.Steps == nil {
		ps.Steps = make(map[string]ProgressStatus)
	}
	ps.Steps[stepName] = status
}

// ProjectManager is an interface for loading/saving a project, adding modules/logs, marking progress.
type ProjectManager interface {
	LoadProject(ctx context.Context, path string) (*Project, error)
	SaveProject(ctx context.Context, path string, p *Project) error
	AddModule(ctx context.Context, p *Project, mod ModuleSpec) error
	AddLog(ctx context.Context, p *Project, msg string) error
	MarkProgress(ctx context.Context, p *Project, stepName string, status ProgressStatus) error
}

// DefaultProjectManager is a reference YAML-based manager.
type DefaultProjectManager struct{}

func (dpm *DefaultProjectManager) LoadProject(ctx context.Context, path string) (*Project, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read file: %w", err)
	}
	var proj Project
	if err := yaml.Unmarshal(data, &proj); err != nil {
		return nil, fmt.Errorf("unmarshal project: %w", err)
	}
	return &proj, nil
}

func (dpm *DefaultProjectManager) SaveProject(ctx context.Context, path string, p *Project) error {
	out, err := yaml.Marshal(p)
	if err != nil {
		return fmt.Errorf("marshal project: %w", err)
	}
	if err := os.WriteFile(path, out, 0644); err != nil {
		return fmt.Errorf("write file: %w", err)
	}
	return nil
}

func (dpm *DefaultProjectManager) AddModule(ctx context.Context, p *Project, mod ModuleSpec) error {
	p.Modules = append(p.Modules, mod)
	return nil
}

func (dpm *DefaultProjectManager) AddLog(ctx context.Context, p *Project, msg string) error {
	p.Logs = append(p.Logs, msg)
	return nil
}

func (dpm *DefaultProjectManager) MarkProgress(ctx context.Context, p *Project, stepName string, status ProgressStatus) error {
	p.Progress.MarkStep(stepName, status)
	return nil
}
EOF

###############################################################################
# 5) internal/memory
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/README.md"
# internal/memory

Handles code/doc/log retrieval, each via a single-responsibility interface:

- **CodeSource**: `GetCode(ctx, query string) (string, error)`
- **DocSource**: `GetDoc(ctx, query string) (string, error)`
- **LogSource**: `GetLog(ctx, query string) (string, error)`

Then we can have an **aggregator** (`MemoryAggregator`) that composes them 
if the coordinator only calls one method.

## Sub-package `db/`
Defines an abstract interface for an embedded vector DB (like `chromem-go`), 
so we can store embeddings and do approximate or exact similarity search.

EOF

cat <<'EOF' > "$PROJECT_DIR/internal/memory/code.go"
package memory

import "context"

// CodeSource is a single-responsibility interface for retrieving code lines or references.
type CodeSource interface {
	GetCode(ctx context.Context, query string) (string, error)
}
EOF

cat <<'EOF' > "$PROJECT_DIR/internal/memory/doc.go"
package memory

import "context"

// DocSource handles retrieving doc paragraphs or textual references.
type DocSource interface {
	GetDoc(ctx context.Context, query string) (string, error)
}
EOF

cat <<'EOF' > "$PROJECT_DIR/internal/memory/log.go"
package memory

import "context"

// LogSource fetches ephemeral log content or messages.
type LogSource interface {
	GetLog(ctx context.Context, query string) (string, error)
}
EOF

cat <<'EOF' > "$PROJECT_DIR/internal/memory/aggregator.go"
package memory

import (
	"context"
	"errors"
	"strings"
)

// MemoryAggregator composes code/doc/log sources if you want a single aggregator approach.
type MemoryAggregator struct {
	Code CodeSource
	Doc  DocSource
	Log  LogSource
}

// GetMemory is a single aggregator method, parse query prefix for code/doc/log
func (ma *MemoryAggregator) GetMemory(ctx context.Context, query string) (string, error) {
	switch {
	case strings.HasPrefix(query, "code:"):
		if ma.Code == nil {
			return "", errors.New("code source is nil")
		}
		return ma.Code.GetCode(ctx, strings.TrimPrefix(query, "code:"))
	case strings.HasPrefix(query, "doc:"):
		if ma.Doc == nil {
			return "", errors.New("doc source is nil")
		}
		return ma.Doc.GetDoc(ctx, strings.TrimPrefix(query, "doc:"))
	case strings.HasPrefix(query, "log:"):
		if ma.Log == nil {
			return "", errors.New("log source is nil")
		}
		return ma.Log.GetLog(ctx, strings.TrimPrefix(query, "log:"))
	default:
		return "", errors.New("unrecognized prefix for memory aggregator")
	}
}
EOF

###############################################################################
# 6) internal/memory/db
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/db/README.md"
# internal/memory/db

Abstract interface for an embedded vector DB, letting us store text chunks 
and do similarity queries (either exact or approximate).

You can implement it with "chromem-go" or any other library.

EOF

cat <<'EOF' > "$PROJECT_DIR/internal/memory/db/db.go"
package db

import "context"

// DB is an interface for storing text and retrieving topK matches by similarity.
type DB interface {
	StoreText(ctx context.Context, chunkID, text string) error
	QueryText(ctx context.Context, query string, topK int) ([]Result, error)
}

type Result struct {
	ChunkID string
	Text    string
	Score   float32
}
EOF

###############################################################################
# 7) internal/runner
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/runner/README.md"
# internal/runner

A whitelisted local command runner, letting the LLM or coordinator run commands 
like `grep` or `ls` in a safe manner.

## Interfaces

- **ExecRunner**: Runs a command if it's in the allowlist
- **AllowedRunner**: Reference implementation storing allowed commands in a map

EOF

cat <<'EOF' > "$PROJECT_DIR/internal/runner/runner.go"
package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// Request is a single command + arguments
type Request struct {
	Command string
	Args    []string
}

// Response holds stdout, stderr, or error
type Response struct {
	Stdout string
	Stderr string
	Error  error
}

// ExecRunner is a single-responsibility interface for running local commands in a restricted environment
type ExecRunner interface {
	RunCommand(ctx context.Context, req Request) Response
}

// AllowedRunner references a map of allowed commands
type AllowedRunner struct {
	Allowed map[string]bool
}

func (ar *AllowedRunner) RunCommand(ctx context.Context, req Request) Response {
	var r Response
	if !ar.Allowed[req.Command] {
		r.Error = errors.New("command not in allowlist")
		return r
	}
	cmd := exec.CommandContext(ctx, req.Command, req.Args...)
	var out, er bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &er
	err := cmd.Run()
	r.Stdout = out.String()
	r.Stderr = er.String()
	r.Error = err
	return r
}

// ParseLine splits a user command line string into a Request
func ParseLine(line string) Request {
	parts := strings.Fields(line)
	if len(parts) == 0 {
		return Request{}
	}
	return Request{Command: parts[0], Args: parts[1:]}
}
EOF

###############################################################################
# 8) internal/coordinator
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/coordinator/README.md"
# internal/coordinator

Coordinates the AI-driven code changes. It references:

- **MemoryAggregator** (or specialized code/doc/log sources) for context retrieval
- **runner.ExecRunner** for local command usage
- **patch.Applier** to apply changes
- **validator.Pipeline** to test/lint
- An **LLM** implementing `PatchGenerator`

## Single Responsibility

- Only orchestrates prompt -> patch -> apply -> validate, 
  delegating to memory, runner, patch, and validator.
EOF

cat <<'EOF' > "$PROJECT_DIR/internal/coordinator/coordinator.go"
package coordinator

import (
	"context"
	"fmt"
	"strings"

	"github.com/yourorg/kazi/internal/memory"
	"github.com/yourorg/kazi/internal/patch"
	"github.com/yourorg/kazi/internal/runner"
	"github.com/yourorg/kazi/internal/validator"
)

// PatchGenerator is the interface for LLM-based patch creation
type PatchGenerator interface {
	GeneratePatch(ctx context.Context, prompt string) (*patch.PatchSet, error)
}

// Coordinator orchestrates the entire LLM-driven workflow
type Coordinator interface {
	ProcessPrompt(ctx context.Context, userPrompt string) error
}

// DefaultCoordinator references memory aggregator, runner, LLM, patch applier, validator
type DefaultCoordinator struct {
	Memory    *memory.MemoryAggregator
	Runner    runner.ExecRunner
	LLM       PatchGenerator
	Applier   patch.Applier
	Validator validator.Pipeline
}

// ProcessPrompt handles user prompt -> patch generation -> apply -> validate
func (dc *DefaultCoordinator) ProcessPrompt(ctx context.Context, userPrompt string) error {
	pset, err := dc.LLM.GeneratePatch(ctx, userPrompt)
	if err != nil {
		return fmt.Errorf("LLM gen patch: %w", err)
	}
	if pset == nil {
		return fmt.Errorf("nil patchset returned")
	}

	// If patch subject says NEED_MEMORY: or RUN_CMD:
	if strings.Contains(pset.Subject, "NEED_MEMORY:") {
		memKey := parseMemoryKey(pset.Subject)
		content, err := dc.Memory.GetMemory(ctx, memKey)
		if err == nil && content != "" {
			newPrompt := userPrompt + "\n\n[MEMORY OUTPUT]\n" + content
			pset, err = dc.LLM.GeneratePatch(ctx, newPrompt)
			if err != nil {
				return err
			}
		}
	}

	if strings.Contains(pset.Subject, "RUN_CMD:") {
		cmdLine := parseCmd(pset.Subject)
		req := runner.ParseLine(cmdLine)
		resp := dc.Runner.RunCommand(ctx, req)
		if resp.Error == nil && resp.Stdout != "" {
			newPrompt := userPrompt + "\n\n[COMMAND OUTPUT]\n" + resp.Stdout
			pset, err = dc.LLM.GeneratePatch(ctx, newPrompt)
			if err != nil {
				return err
			}
		}
	}

	err = dc.Applier.Apply(ctx, pset)
	if err != nil {
		return fmt.Errorf("apply patch: %w", err)
	}
	res := dc.Validator.ValidateAll(ctx)
	if !res.Success {
		return fmt.Errorf("validation failed: %v", res.Error())
	}

	fmt.Println("Patch applied & validated successfully!")
	return nil
}

func parseMemoryKey(subj string) string {
	// naive placeholder
	return "code:UserRepo"
}

func parseCmd(subj string) string {
	// naive placeholder
	return "grep -n 'UserRepository'"
}
EOF

###############################################################################
# 9) internal/patch
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/patch/README.md"
# internal/patch

Minimal patch-based editing approach. The LLM returns a `PatchSet` describing line-level or 
file-based edits. We apply them locally. 

## Single Responsibility

- Only handle code modifications. 
- `PatchSet.Subject` can hold instructions (like "NEED_MEMORY: code:UserRepo") 
  or "RUN_CMD: grep ...", which the coordinator might parse.

EOF

cat <<'EOF' > "$PROJECT_DIR/internal/patch/patch.go"
package patch

import "context"

// PatchSet is a group of changes, plus a subject that may hold LLM instructions
type PatchSet struct {
	Subject string
	Patches []PatchOperation
}

type PatchOperation struct {
	File string
	FromLine int
	ToLine   int
	Content  string
}

// Applier is a single interface for applying these changes
type Applier interface {
	Apply(ctx context.Context, ps *PatchSet) error
}

type DefaultApplier struct{}

func (da *DefaultApplier) Apply(ctx context.Context, ps *PatchSet) error {
	// In real usage, read file lines, replace from FromLine to ToLine with Content
	return nil
}
EOF

###############################################################################
# 10) internal/validator
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/validator/README.md"
# internal/validator

Renamed from "validation". Provides a pipeline for build/test (and optionally security scanning) checks.

## Single Responsibility

- Only checks code correctness or security. 
- Returns a `ValidationResult` capturing success or error details.

EOF

cat <<'EOF' > "$PROJECT_DIR/internal/validator/validator.go"
package validator

import "context"

// Pipeline runs multiple checks (lint, tests, security) in sequence or parallel.
type Pipeline interface {
	ValidateAll(ctx context.Context) ValidationResult
}

// ValidationResult holds success or errors
type ValidationResult struct {
	Success bool
	Errors  []error
}

func (vr ValidationResult) Error() string {
	return "validation error(s)"
}

// DefaultPipeline is a minimal reference that could run commands or concurrency
type DefaultPipeline struct{}

func (dp *DefaultPipeline) ValidateAll(ctx context.Context) ValidationResult {
	// e.g. run lint, test, security checks in parallel
	return ValidationResult{Success:true}
}
EOF

echo "Kazi final interface-first scaffold created in $PROJECT_DIR with detailed READMEs!"
