package patch

import "context"

// PatchSet describes line or file changes plus subject.
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

// Applier is a single interface with Apply method
type Applier interface {
	Apply(ctx context.Context, ps *PatchSet) error
}

type DefaultApplier struct{}

func (da *DefaultApplier) Apply(ctx context.Context, ps *PatchSet) error {
	// placeholder
	return nil
}
