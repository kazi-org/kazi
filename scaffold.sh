#!/bin/bash
set -e

# This script scaffolds the Kazi project with an interface-first design.
# It creates the directory structure and populates the project with code
# that includes detailed documentation at the package and type level.

echo "Scaffolding Kazi project..."

# Create directories
mkdir -p cmd/kazi
mkdir -p internal/coordinator
mkdir -p internal/config
mkdir -p internal/lsp
mkdir -p internal/vision
mkdir -p internal/architecture
mkdir -p internal/patch
mkdir -p internal/knowledge
mkdir -p internal/validation

# Create main CLI entry point
cat << 'EOF' > cmd/kazi/main.go
// cmd/kazi/main.go
//
// Package main provides the CLI entry point for the Kazi system.
// In a real-world application, this would parse command-line arguments,
// initialize configuration, and delegate tasks (such as planning, building,
// testing, and deployment) to the appropriate modules.
package main

import (
	"fmt"
	"os"
	// "github.com/kazi-org/kazi/internal/config"
	// "github.com/kazi-org/kazi/internal/coordinator"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: kazi <command> [args]")
		os.Exit(1)
	}
	subcommand := os.Args[1]

	switch subcommand {
	case "prompt":
		// Example: `kazi prompt "Implement X feature"`
		fmt.Println("Prompt subcommand not yet implemented.")
	default:
		fmt.Printf("Unknown subcommand: %s\n", subcommand)
	}
}
EOF

# Create coordinator package
cat << 'EOF' > internal/coordinator/coordinator.go
// internal/coordinator/coordinator.go
//
// Package coordinator orchestrates the prompt -> patch -> validation loop.
// It bridges the user’s intent with the underlying system components, including
// the Vision Contract, Architecture Manager, Patch Applier, and Validation Pipeline.
package coordinator

import (
	"github.com/kazi-org/kazi/internal/architecture"
	"github.com/kazi-org/kazi/internal/patch"
	"github.com/kazi-org/kazi/internal/validation"
	"github.com/kazi-org/kazi/internal/vision"
)

// Coordinator defines the core interface for running code-generation cycles.
type Coordinator interface {
	// ProcessPrompt handles the user prompt by:
	// 1. Gathering context from the Vision Contract and Architecture.
	// 2. Calling the LLM to generate a patch.
	// 3. Applying the patch.
	// 4. Running validations.
	// 5. Committing or reverting changes.
	ProcessPrompt(prompt string) error
}

// DefaultCoordinator is a reference implementation of the Coordinator interface.
// It composes a Vision Contract, an Architecture Manager, a Patch Applier, and a Validation Pipeline.
type DefaultCoordinator struct {
	Contract            *vision.Contract
	ArchitectureManager architecture.Manager
	PatchApplier        patch.Applier
	Validator           validation.Pipeline
	// Additional fields (e.g., LLM client, knowledge store) can be added here.
}

// ProcessPrompt orchestrates the workflow for processing a user prompt.
func (dc *DefaultCoordinator) ProcessPrompt(prompt string) error {
	// TODO: Implement the workflow:
	// 1. Retrieve context (Vision Contract + Architecture).
	// 2. Call the LLM to produce a patch.
	// 3. Apply the patch.
	// 4. Validate changes.
	// 5. Commit or revert based on validation.
	return nil
}
EOF

# Create config package
cat << 'EOF' > internal/config/manifest.go
// internal/config/manifest.go
//
// Package config manages the Kubernetes-style manifest that holds the operational
// configuration and vision for the Kazi project.
//
// Example manifest (.kazi.yaml):
//   apiVersion: kazi.bot/v1
//   kind: Project
//   metadata:
//     name: my-project
//   spec:
//     config:
//       workspace: "/path/to/project"
//       lintCommand: "go vet ./..."
//       testCommand: "go test ./..."
package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Project represents the top-level structure of the Kazi configuration manifest.
type Project struct {
	APIVersion string   `yaml:"apiVersion"`
	Kind       string   `yaml:"kind"`
	Metadata   Metadata `yaml:"metadata"`
	Spec       Spec     `yaml:"spec"`
}

// Metadata holds standard Kubernetes-style metadata.
type Metadata struct {
	Name   string            `yaml:"name"`
	Labels map[string]string `yaml:"labels,omitempty"`
}

// Spec merges the Vision Contract and operational configuration.
type Spec struct {
	Config Config `yaml:"config"`
}

// Config contains operational details such as workspace and commands for linting/testing.
type Config struct {
	Workspace   string `yaml:"workspace"`
	LintCommand string `yaml:"lintCommand"`
	TestCommand string `yaml:"testCommand"`
}

// LoadManifest reads a .kazi.yaml manifest file and decodes it into a Project structure.
func LoadManifest(path string) (*Project, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open manifest file %q: %w", path, err)
	}
	defer f.Close()

	var project Project
	decoder := yaml.NewDecoder(f)
	if err := decoder.Decode(&project); err != nil {
		return nil, fmt.Errorf("decode YAML from %q: %w", path, err)
	}

	// Provide sensible defaults if fields are missing.
	if project.APIVersion == "" {
		project.APIVersion = "kazi.bot/v1"
	}
	if project.Kind == "" {
		project.Kind = "Project"
	}
	cfg := &project.Spec.Config
	if cfg.Workspace == "" {
		cfg.Workspace = "."
	}
	if cfg.LintCommand == "" {
		cfg.LintCommand = "go vet ./..."
	}
	if cfg.TestCommand == "" {
		cfg.TestCommand = "go test ./..."
	}

	return &project, nil
}
EOF

# Create LSP package
cat << 'EOF' > internal/lsp/lsp.go
// internal/lsp/lsp.go
//
// Package lsp defines interfaces to interact with a Language Server Protocol (LSP) client
// or any code-analysis service. It supports code formatting and analysis to ensure
// code quality and adherence to style/security standards.
package lsp

// Issue represents a code issue or warning identified by the LSP.
type Issue struct {
	Severity string // e.g., "warning" or "error"
	Message  string // Detailed message about the issue
	Line     int    // Line number where the issue was found
	Column   int    // Column number where the issue was found
}

// Client defines an interface for interacting with an LSP or code analysis service.
type Client interface {
	// FormatCode returns a properly formatted version of the file content.
	FormatCode(filePath string) (string, error)

	// AnalyzeFile returns a list of issues or warnings found in the file.
	AnalyzeFile(filePath string) ([]Issue, error)
}
EOF

# Create vision package
cat << 'EOF' > internal/vision/vision.go
// internal/vision/vision.go
//
// Package vision defines the Vision Contract which specifies the high-level requirements
// and constraints that guide the code generation process. This contract ensures that
// all generated code aligns with key business objectives and compliance needs.
package vision

// Contract represents the Vision Contract: a description of the intended software,
// including its objectives and constraints (e.g., compliance requirements).
type Contract struct {
	Name        string            // Name of the vision, e.g., "Payment Gateway Integration"
	Description string            // High-level summary of the product requirements
	Constraints map[string]string // Constraints (e.g., {"compliance": "PCI-DSS", "language": "Go"})
}
EOF

# Create vision YAML loader
cat << 'EOF' > internal/vision/yaml_loader.go
// internal/vision/yaml_loader.go
//
// Package vision provides a YAMLLoader to read the Vision Contract from a YAML file.
package vision

import (
	"os"

	"gopkg.in/yaml.v3"
)

// YAMLLoader implements the Loader interface for Vision Contracts, reading them from YAML files.
type YAMLLoader struct{}

// LoadContract reads a Vision Contract from the specified YAML file.
func (l *YAMLLoader) LoadContract(pathOrData string) (*Contract, error) {
	data, err := os.ReadFile(pathOrData)
	if err != nil {
		return nil, err
	}

	var contract Contract
	if err := yaml.Unmarshal(data, &contract); err != nil {
		return nil, err
	}

	return &contract, nil
}
EOF

# Create architecture package
cat << 'EOF' > internal/architecture/architecture.go
// internal/architecture/architecture.go
//
// Package architecture provides interfaces and types for representing
// the system design, including modules, interfaces, and code chunking
// for LLM processing.
package architecture

import (
	"github.com/kazi-org/kazi/internal/vision"
)

// Architecture represents the high-level system design and codebase structure.
// It is composed of multiple modules and interfaces defining the system's components.
type Architecture struct {
	Modules []ModuleSpec // List of modules in the system
}

// ModuleSpec describes an individual module or subsystem.
type ModuleSpec struct {
	Name       string           // Name of the module
	Interfaces []InterfaceSpec  // Interfaces provided by the module
}

// InterfaceSpec defines a contract (or API) for a module.
type InterfaceSpec struct {
	Name    string      // Name of the interface
	Methods []MethodSig // Function signatures within the interface
}

// MethodSig represents a minimal definition of a function signature.
type MethodSig struct {
	Name       string   // Name of the method
	Parameters []string // Parameters (type or name) required by the method
	Returns    []string // Return types of the method
}

// Manager defines how to build and update the Architecture from the Vision Contract,
// and how to chunk code for LLM processing.
type Manager interface {
	// BuildArchitecture constructs the system design based on the provided Vision Contract.
	BuildArchitecture(contract *vision.Contract) (*Architecture, error)

	// ProvideChunks returns slices of code relevant to a module or file,
	// ensuring the LLM's context window is not exceeded.
	ProvideChunks(moduleOrFile string, maxTokens int) ([]string, error)
}
EOF

# Create patch package
cat << 'EOF' > internal/patch/patch.go
// internal/patch/patch.go
//
// Package patch defines the data structures and interfaces for patch-based editing.
// A patch represents a set of changes (create, replace, or delete) to be applied to the codebase.
package patch

// PatchSet describes a collection of patch operations to perform on the codebase.
type PatchSet struct {
	Subject string           // A summary or commit message describing the patch set
	Patches []PatchOperation // A list of individual patch operations
}

// PatchOperation represents a single modification to a file.
type PatchOperation struct {
	File        string   // File path to be modified
	Type        string   // Type of operation: "create", "replace", or "delete"
	FromLine    int      // Starting line number (for replace/delete)
	ToLine      int      // Ending line number (for replace/delete)
	Content     string   // New content (for create/replace)
	LinesBefore []string // Contextual lines before the change
	LinesAfter  []string // Contextual lines after the change
}

// Applier defines an interface for applying PatchSets to the local filesystem or repository.
type Applier interface {
	// Apply applies the given PatchSet, returning an error if the operation fails.
	Apply(ps *PatchSet) error
}
EOF

# Create knowledge package
cat << 'EOF' > internal/knowledge/knowledge.go
// internal/knowledge/knowledge.go
//
// Package knowledge provides interfaces for logging historical data about patch operations,
// including recording successes and failures.
package knowledge

// Store defines an interface for recording the outcomes of patch operations.
type Store interface {
	// RecordSuccess logs a successful patch operation.
	RecordSuccess(operationID string) error

	// RecordFailure logs a failed patch operation along with the failure reason.
	RecordFailure(operationID, reason string) error
}
EOF

# Create validation package
cat << 'EOF' > internal/validation/validation.go
// internal/validation/validation.go
//
// Package validation defines a pipeline of checks (lint, tests, security, etc.)
// to ensure that the codebase is correct, secure, and production-ready after patches are applied.
package validation

// Pipeline defines an interface for running multiple validations on the codebase.
type Pipeline interface {
	// ValidateAll runs all configured validations (e.g., linting, tests, security scans)
	// and returns an error if any check fails.
	ValidateAll() error
}

// DefaultPipeline is a basic implementation of the Pipeline interface.
// It stores configuration for lint and test commands and can be extended to run additional validations.
type DefaultPipeline struct {
	LintCommand string // Command for linting, e.g., "go vet ./..."
	TestCommand string // Command for testing, e.g., "go test ./..."
}

// ValidateAll executes the configured lint and test commands.
// In a full implementation, this function would run the commands and aggregate results.
func (p *DefaultPipeline) ValidateAll() error {
	// TODO: Implement actual command execution and result aggregation.
	return nil
}
EOF

echo "Kazi project scaffolded successfully."
