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
