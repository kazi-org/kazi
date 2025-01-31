// validator.go
//
// Provides a Validator interface to check feasibility of patch operations
// (line ranges, file existence, context matching) before we attempt to apply them.

package patch

import "context"

// Validator checks if a patch can be safely applied to the workspace.
type Validator interface {
	Validate(ctx context.Context, ps *PatchSet) error
}

// ExampleValidator is a trivial reference that ensures line ranges are valid and
// "create" doesn't already exist, etc. We rely on a FileManager for knowledge of
// file states. This could be integrated with concurrency as well, but we keep it simple.
type ExampleValidator struct {
	FileMgr FileManager
}

func (ev *ExampleValidator) Validate(ctx context.Context, ps *PatchSet) error {
	// For each patch, do minimal checks:
	for _, op := range ps.Patches {
		switch op.Type {
		case PatchCreate:
			exists, err := ev.FileMgr.Exists(op.File)
			if err != nil {
				return err
			}
			if exists {
				return ErrValidation("file already exists")
			}
		case PatchReplace, PatchDelete:
			// Possibly ensure lines are in range:
			data, err := ev.FileMgr.ReadFile(op.File)
			if err != nil {
				return err
			}
			lines := splitLines(data)
			if op.FromLine < 1 || op.ToLine < op.FromLine || op.ToLine > len(lines) {
				return ErrValidation("out of range lines for replace/delete")
			}
		default:
			return ErrValidation("unknown patch type")
		}
	}
	return nil
}

// ErrValidation is a custom error type for clarity.
type ErrValidation string

func (e ErrValidation) Error() string {
	return string(e)
}
