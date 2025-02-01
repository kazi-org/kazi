package validator

import "context"

// Pipeline runs multiple checks (lint, tests, security) in sequence or parallel.
type Pipeline interface {
	ValidateAll(ctx context.Context) ValidationResult
}

// ValidationResult holds success or errors
type ValidationResult struct {
	Success bool
	Errors  []error
}

func (vr ValidationResult) Error() string {
	return "validation error(s)"
}

// DefaultPipeline is a minimal reference that could run commands or concurrency
type DefaultPipeline struct{}

func (dp *DefaultPipeline) ValidateAll(ctx context.Context) ValidationResult {
	// e.g. run lint, test, security checks in parallel
	return ValidationResult{Success:true}
}
