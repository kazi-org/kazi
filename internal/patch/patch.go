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
