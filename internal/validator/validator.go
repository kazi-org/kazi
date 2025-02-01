package validator

import "context"

// Pipeline is the single interface for build/test checks
type Pipeline interface {
	ValidateAll(ctx context.Context) ValidationResult
}

type ValidationResult struct {
	Success bool
	Errors  []error
}

func (vr ValidationResult) Error() string {
	return "validation error(s)"
}

type DefaultPipeline struct{}

func (dp *DefaultPipeline) ValidateAll(ctx context.Context) ValidationResult {
	return ValidationResult{Success:true}
}
