// pipeline.go
//
// Provides the main Pipeline interface plus a small aggregator approach.
// "Check" is a smaller specialized interface for a single validation step.

package validation

import "context"

// Pipeline defines the main interface for running a set of validations on the codebase.
type Pipeline interface {
	// ValidateAll runs all checks, returning an aggregated error if any fail.
	// It can run them sequentially or concurrently.
	ValidateAll(ctx context.Context) ValidationResult
}

// Check is a smaller specialized interface for a single validation operation.
// e.g. "Run lint", "Run tests", "Run security check".
type Check interface {
	// Name is a short identifier for logging or result display.
	Name() string

	// Run executes the check, returning a partial ValidationResult. We store
	// success/failure info in the returned struct. We do not panic or hide errors.
	Run(ctx context.Context) ValidationResult
}
