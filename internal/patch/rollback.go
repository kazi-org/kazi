// rollback.go
//
// If you want to restore the workspace to a prior state if applying patches fails
// partway, define a Rollbacker interface and a default implementation here.

package patch

import "context"

// Rollbacker handles restoring the workspace if patch application fails mid-way.
// Typically you might store a backup of each file before applying patches, then
// restore them if an error occurs.
type Rollbacker interface {
	BackupBeforeApply(filePath string, originalContent []byte) error
	Rollback(ctx context.Context) error
}

// ExampleRollbacker is a simplistic approach. In production, you'd store backups in memory or disk.
type ExampleRollbacker struct {
	backups map[string][]byte
}

func NewExampleRollbacker() *ExampleRollbacker {
	return &ExampleRollbacker{
		backups: make(map[string][]byte),
	}
}

func (rb *ExampleRollbacker) BackupBeforeApply(filePath string, originalContent []byte) error {
	rb.backups[filePath] = originalContent
	return nil
}

func (rb *ExampleRollbacker) Rollback(ctx context.Context) error {
	// For each file in backups, restore
	// ...
	return nil
}
