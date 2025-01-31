// Package validation supplies a Pipeline interface that runs multiple checks
// on the codebase, ensuring it meets quality standards before final acceptance.

package validation

// Pipeline runs a sequence of checks, returning an error if any fail.
type Pipeline interface {
	ValidateAll() error
}

// DefaultPipeline is a reference implementation that might store shell commands
// for lint/test, then run them in ValidateAll().
type DefaultPipeline struct {
	LintCommand string
	TestCommand string
}

func (p *DefaultPipeline) ValidateAll() error {
	// e.g., run lint (p.LintCommand), run tests (p.TestCommand), gather errors
	return nil
}
