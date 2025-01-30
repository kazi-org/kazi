// Package architecture provides an interface-based approach to representing
// the codebase structure (modules, interfaces) and chunking large files for LLM.

package architecture

import (
	"github.com/yourorg/kazi/internal/vision"
)

// Architecture is a minimal representation of the system design.
type Architecture struct {
	Modules []ModuleSpec
}

// ModuleSpec describes a single module or subsystem.
type ModuleSpec struct {
	Name       string
	Interfaces []InterfaceSpec
}

// InterfaceSpec describes a contract or API each module might implement.
type InterfaceSpec struct {
	Name    string
	Methods []MethodSig
}

// MethodSig is a minimal definition of a function signature.
type MethodSig struct {
	Name       string
	Parameters []string
	Returns    []string
}

// Manager defines how we build or update the Architecture from the Vision
// Contract, and how we chunk code for LLM.
type Manager interface {
	// BuildArchitecture uses the Vision Contract and possibly scans existing code
	// to produce a high-level Architecture.
	BuildArchitecture(contract *vision.Contract) (*Architecture, error)

	// ProvideChunks returns slices of code relevant to a specific file/module,
	// ensuring we don't exceed LLM context size.
	ProvideChunks(moduleOrFile string, maxTokens int) ([]string, error)
}
