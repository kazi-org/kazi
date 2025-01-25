package patch

// Applier defines the interface for applying patches to a workspace
type Applier interface {
	// Apply applies the patches to the workspace
	Apply(ps *PatchSet) error
}
