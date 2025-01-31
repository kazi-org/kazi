// patch.go
//
// Defines the fundamental data structures for describing patch sets and operations.
// Each PatchOperation references a file, operation type, line ranges, content, etc.
// This file doesn't apply patches; it only models them.

package patch

// PatchType enumerates the types of patch operations that can occur.
type PatchType string

const (
	PatchCreate  PatchType = "create"
	PatchReplace PatchType = "replace"
	PatchDelete  PatchType = "delete"
)

// PatchOperation represents a single text modification within a file.
type PatchOperation struct {
	File string    // Path to the file to be modified
	Type PatchType // Type of operation (create, replace, delete)

	// For replace or delete, line range is mandatory (1-based).
	FromLine int
	ToLine   int

	// For create or replace, new content to insert.
	Content string

	// linesBefore / linesAfter can be used to match context lines
	// or ensure the patch is at the right place.
	LinesBefore []string
	LinesAfter  []string
}

// PatchSet groups a list of PatchOperation items under a short Subject
// or commit-like message.
type PatchSet struct {
	Subject string
	Patches []PatchOperation
}
