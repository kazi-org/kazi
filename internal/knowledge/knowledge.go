// Package knowledge logs patch successes/failures to track how the system evolves.

package knowledge

// Store records success/failure or other historical data about patches/operations.
type Store interface {
	RecordSuccess(operationID string) error
	RecordFailure(operationID, reason string) error
}
