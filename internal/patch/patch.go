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
