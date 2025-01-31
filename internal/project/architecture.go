// architecture.go
//
// Defines the blueprint portion of the project, including modules, interfaces, and methods.
// This doesn't handle domain or config logic; it solely focuses on "how the system is structured."

package project

// Architecture is the top-level blueprint capturing modules and their interfaces.
type Architecture struct {
	Modules []ModuleSpec
}

// ModuleSpec describes a single subsystem (module) in the blueprint.
type ModuleSpec struct {
	Name       string
	Interfaces []InterfaceSpec
}

// InterfaceSpec defines a contract or API that a module must implement.
type InterfaceSpec struct {
	Name    string
	Methods []MethodSig
}

// MethodSig describes a single method signature within an interface.
type MethodSig struct {
	Name       string
	Parameters []string
	Returns    []string
}

// ArchitectureManager is responsible for loading or updating
// the system's architecture blueprint.
type ArchitectureManager interface {
	// LoadArchitecture loads or constructs the Architecture (maybe from scanning code or a YAML).
	LoadArchitecture(pathOrData string) (*Architecture, error)

	// UpdateArchitecture modifies the existing Architecture (e.g., add a new module).
	UpdateArchitecture(a *Architecture) error
}
