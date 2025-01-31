// internal/knowledge/knowledge.go
//
// Package knowledge provides interfaces for logging historical data about patch operations,
// including recording successes and failures.
package knowledge

// Store defines an interface for recording the outcomes of patch operations.
type Store interface {
	// RecordSuccess logs a successful patch operation.
	RecordSuccess(operationID string) error

	// RecordFailure logs a failed patch operation along with the failure reason.
	RecordFailure(operationID, reason string) error
}
