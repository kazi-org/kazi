// Package patch defines the data structures and interfaces for minimal
// patch-based editing.

package patch

// PatchSet describes a collection of patch operations to perform.
type PatchSet struct {
	Subject string         // e.g., commit message or summary
	Patches []PatchOperation
}

// PatchOperation represents a single create/replace/delete action on a file.
type PatchOperation struct {
	File        string
	Type        string // "create", "replace", "delete"
	FromLine    int
	ToLine      int
	Content     string
	LinesBefore []string
	LinesAfter  []string
}

// Applier applies patch sets to the local filesystem or code repo.
type Applier interface {
	Apply(ps *PatchSet) error
}
