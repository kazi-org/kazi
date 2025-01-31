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
