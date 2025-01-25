package patch

// patchApplier implements the Applier interface
type patchApplier struct {
	workspace string
}

// NewApplier creates a new patch applier for the given workspace
func NewApplier(workspace string) Applier {
	return &patchApplier{
		workspace: workspace,
	}
}

// Apply applies the patches to the workspace
func (pa *patchApplier) Apply(ps *PatchSet) error {
	return ps.Apply(pa.workspace)
}
