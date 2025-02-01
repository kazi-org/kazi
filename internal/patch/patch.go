package patch

import "context"

// PatchSet is a group of changes, plus a subject that may hold LLM instructions
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

// Applier is a single interface for applying these changes
type Applier interface {
	Apply(ctx context.Context, ps *PatchSet) error
}

type DefaultApplier struct{}

func (da *DefaultApplier) Apply(ctx context.Context, ps *PatchSet) error {
	// In real usage, read file lines, replace from FromLine to ToLine with Content
	return nil
}
