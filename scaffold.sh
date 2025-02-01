#!/usr/bin/env bash
#
# bootstrap_kazi_final.sh
#
# Creates the final Kazi scaffold with directories:
#   - memory/ (was contextsource)
#   - memory/db (was embeddb)
#   - runner/ (was systemexec)
#   - validator/ (was validation)
# Plus splitting aggregator into smaller single-responsibility interfaces for code, doc, log, etc.
#
# Usage:
#   ./bootstrap_kazi_final.sh <PROJECT_DIR>
#

set -euo pipefail

PROJECT_DIR="${1:-kazi-final}"

echo "Creating final refined Kazi scaffold in: $PROJECT_DIR"

###############################################################################
# 1) CREATE DIRECTORIES
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
EOF

###############################################################################
# 3) cmd/kazi/main.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/cmd/kazi/main.go"
// Package main provides a minimal CLI with subcommands:
//   kazi init
//   kazi build
//   kazi deploy
//   kazi prompt "..." 
// Implementation is left as placeholders.

package main

import (
	"fmt"
	"os"
)

func usage() {
	fmt.Println(`kazi final - usage:
  kazi init
  kazi build
  kazi deploy
  kazi prompt "..."`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	subcommand := os.Args[1]
	switch subcommand {
	case "init":
		fmt.Println("[INIT] placeholder")
	case "build":
		fmt.Println("[BUILD] placeholder")
	case "deploy":
		fmt.Println("[DEPLOY] placeholder")
	case "prompt":
		fmt.Println("[PROMPT] placeholder")
	default:
		fmt.Printf("unknown subcommand: %s\n", subcommand)
		usage()
	}
}
EOF

###############################################################################
# 4) internal/project/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/project/README.md"
# project

Single `Project` struct merges domain, config, architecture, ephemeral logs, chunk references, progress. 
A `ProjectManager` interface to load/save. 
EOF

###############################################################################
# 5) internal/project/project.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/project/project.go"
package project

import (
	"context"
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Project merges domain constraints, architecture, config, ephemeral logs, chunk references, progress
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

// ProgressState tracks a map of stepName -> status
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

// ProjectManager for loading/saving
type ProjectManager interface {
	LoadProject(ctx context.Context, path string) (*Project, error)
	SaveProject(ctx context.Context, path string, p *Project) error
	AddModule(ctx context.Context, p *Project, mod ModuleSpec) error
	AddLog(ctx context.Context, p *Project, msg string) error
	MarkProgress(ctx context.Context, p *Project, stepName string, status ProgressStatus) error
}

// DefaultProjectManager for a simple YAML-based approach
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
# 6) internal/memory/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/README.md"
# memory

Renamed from "contextsource". 
We define smaller single-responsibility interfaces for code, doc, log retrieval, 
plus an aggregator that composes them if needed. 
We also have a sub-package `db` for the vector/embedding database (formerly embeddb).
EOF

###############################################################################
# 7) internal/memory/code.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/code.go"
package memory

import "context"

// CodeSource fetches code references or lines. Single responsibility.
type CodeSource interface {
	GetCode(ctx context.Context, query string) (string, error)
}
EOF

###############################################################################
# 8) internal/memory/doc.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/doc.go"
package memory

import "context"

// DocSource fetches doc references or paragraphs. Single responsibility.
type DocSource interface {
	GetDoc(ctx context.Context, query string) (string, error)
}
EOF

###############################################################################
# 9) internal/memory/log.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/log.go"
package memory

import "context"

// LogSource fetches logs or ephemeral notes. Single responsibility.
type LogSource interface {
	GetLog(ctx context.Context, query string) (string, error)
}
EOF

###############################################################################
# 10) internal/memory/aggregator.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/aggregator.go"
package memory

import (
	"context"
	"errors"
	"strings"
)

// MemoryAggregator composes smaller interfaces, implementing code/doc/log retrieval 
// plus a fallback to the underlying DB if needed.
type MemoryAggregator struct {
	Code   CodeSource
	Doc    DocSource
	Log    LogSource
}

// GetMemory attempts to figure out if query is "code:", "doc:", "log:" 
// then calls the relevant interface. 
// If no prefix matches, we return an error or empty string.
func (ma *MemoryAggregator) GetMemory(ctx context.Context, query string) (string, error) {
	switch {
	case strings.HasPrefix(query, "code:"):
		if ma.Code == nil {
			return "", errors.New("code source not configured")
		}
		return ma.Code.GetCode(ctx, strings.TrimPrefix(query, "code:"))
	case strings.HasPrefix(query, "doc:"):
		if ma.Doc == nil {
			return "", errors.New("doc source not configured")
		}
		return ma.Doc.GetDoc(ctx, strings.TrimPrefix(query, "doc:"))
	case strings.HasPrefix(query, "log:"):
		if ma.Log == nil {
			return "", errors.New("log source not configured")
		}
		return ma.Log.GetLog(ctx, strings.TrimPrefix(query, "log:"))
	default:
		return "", errors.New("unknown memory query prefix")
	}
}
EOF

###############################################################################
# 11) internal/memory/db/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/db/README.md"
# db

Renamed from `embeddb`. 
Interface for a vector database storing text, returning top-k results via similarity.
We can plug in `chromem-go` or another solution behind it.
EOF

###############################################################################
# 12) internal/memory/db/db.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/memory/db/db.go"
package db

import "context"

// DB is the interface for storing text + retrieving topK relevant results 
// via embeddings-based similarity. Formerly embeddb, we can use e.g. chromem-go.

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
# 13) internal/runner/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/runner/README.md"
# runner

Renamed from `systemexec`. 
We define a whitelisted local command runner interface, single responsibility: run commands.
EOF

###############################################################################
# 14) internal/runner/runner.go
###############################################################################
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

// Request for a system command
type Request struct {
	Command string
	Args    []string
}

// Response after running
type Response struct {
	Stdout string
	Stderr string
	Error  error
}

// ExecRunner is the single interface
type ExecRunner interface {
	RunCommand(ctx context.Context, req Request) Response
}

// AllowedRunner references a allowlist
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

func ParseLine(line string) Request {
	parts := strings.Fields(line)
	if len(parts) == 0 {
		return Request{}
	}
	return Request{Command: parts[0], Args: parts[1:]}
}
EOF

###############################################################################
# 15) internal/coordinator/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/coordinator/README.md"
# coordinator

Orchestrates the prompt -> LLM -> patch -> validation flow. 
References:
- `memory` aggregator for code/docs/log retrieval
- `runner` for whitelisted local commands
- `patch` for code edits
- `validator` for build/test checks
EOF

###############################################################################
# 16) internal/coordinator/coordinator.go
###############################################################################
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

// PatchGenerator is an interface for LLM-based patch generation
type PatchGenerator interface {
	GeneratePatch(ctx context.Context, prompt string) (*patch.PatchSet, error)
}

// Coordinator orchestrates the entire flow
type Coordinator interface {
	ProcessPrompt(ctx context.Context, userPrompt string) error
}

// DefaultCoordinator composes memory aggregator, runner, patch logic, validator, plus an LLM generator
type DefaultCoordinator struct {
	Memory    *memory.MemoryAggregator
	Runner    runner.ExecRunner
	LLM       PatchGenerator
	Applier   patch.Applier
	Validator validator.Pipeline
}

func (dc *DefaultCoordinator) ProcessPrompt(ctx context.Context, userPrompt string) error {
	pset, err := dc.LLM.GeneratePatch(ctx, userPrompt)
	if err != nil {
		return fmt.Errorf("llm gen patch: %w", err)
	}
	if pset == nil {
		return fmt.Errorf("patchset is nil")
	}

	// If patch subject says "NEED_MEMORY: code:UserRepo" or "RUN_CMD: grep..."
	if strings.Contains(pset.Subject, "NEED_MEMORY:") {
		key := parseMemKey(pset.Subject)
		content, err := dc.Memory.GetMemory(ctx, key)
		if err == nil && content != "" {
			newPrompt := userPrompt + "\n\n[MEMORY CONTENT]\n" + content
			pset, err = dc.LLM.GeneratePatch(ctx, newPrompt)
			if err != nil {
				return err
			}
		}
	}

	if strings.Contains(pset.Subject, "RUN_CMD:") {
		cmdLine := parseCmdLine(pset.Subject)
		req := runner.ParseLine(cmdLine)
		out := dc.Runner.RunCommand(ctx, req)
		if out.Error == nil && out.Stdout != "" {
			newPrompt := userPrompt + "\n\n[COMMAND OUTPUT]\n" + out.Stdout
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

	fmt.Println("Patch applied & validated!")
	return nil
}

func parseMemKey(subj string) string {
	// naive
	return "code:UserRepo"
}

func parseCmdLine(subj string) string {
	return "grep -n 'UserRepository'"
}
EOF

###############################################################################
# 17) internal/patch/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/patch/README.md"
# patch

Minimal patch-based editing. 
EOF

###############################################################################
# 18) internal/patch/patch.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/patch/patch.go"
package patch

import "context"

// PatchSet describes line or file changes plus subject.
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

// Applier is a single interface with Apply method
type Applier interface {
	Apply(ctx context.Context, ps *PatchSet) error
}

type DefaultApplier struct{}

func (da *DefaultApplier) Apply(ctx context.Context, ps *PatchSet) error {
	// placeholder
	return nil
}
EOF

###############################################################################
# 19) internal/validator/README.md
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/validator/README.md"
# validator

Renamed from `validation`. 
A pipeline interface for build/test checks, possibly concurrency-based. 
EOF

###############################################################################
# 20) internal/validator/validator.go
###############################################################################
cat <<'EOF' > "$PROJECT_DIR/internal/validator/validator.go"
package validator

import "context"

// Pipeline is the single interface for build/test checks
type Pipeline interface {
	ValidateAll(ctx context.Context) ValidationResult
}

type ValidationResult struct {
	Success bool
	Errors  []error
}

func (vr ValidationResult) Error() string {
	return "validation error(s)"
}

type DefaultPipeline struct{}

func (dp *DefaultPipeline) ValidateAll(ctx context.Context) ValidationResult {
	return ValidationResult{Success:true}
}
EOF

echo "Final scaffold created at $PROJECT_DIR!"
echo "Renamed systemexec->runner, contextsource->memory, embeddb->db in memory, validation->validator."
echo "Broke aggregator into code/doc/log single-responsibility, used composition in aggregator."
echo "Done!"
