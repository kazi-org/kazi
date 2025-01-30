// Package validation provides a pipeline of checks (lint, tests, security, etc.)
// that ensure patched code is correct and safe.

package validation

// Pipeline runs a series of validations on the current codebase.
type Pipeline interface {
	// ValidateAll runs all checks (lint, tests, etc.). Returns an error if any fail.
	ValidateAll() error
}

// DefaultPipeline is a reference struct that might store commands or config.
type DefaultPipeline struct {
	LintCommand string
	TestCommand string
}

// ValidateAll would run your commands or LSP checks, returning error on failure.
func (p *DefaultPipeline) ValidateAll() error {
	// 1. Possibly run lint (p.LintCommand)
	// 2. Possibly run tests (p.TestCommand)
	// 3. Return nil if all checks pass
	return nil
}
