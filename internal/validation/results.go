// results.go
//
// Provides a structured approach for collecting detailed validation results.
// The final Pipeline might aggregate or unify these into an error if any check fails.

package validation

import (
	"fmt"
	"strings"
)

// ValidationResult holds info about a single check or an entire pipeline run.
type ValidationResult struct {
	// Name of the check or pipeline step, e.g. "LintCheck"
	Name string

	// Success indicates if the check or pipeline completed without errors.
	Success bool

	// Errors collects any reported issues or reasons for failure.
	Errors []error
}

// HasErrors returns true if the result includes one or more errors.
func (vr ValidationResult) HasErrors() bool {
	return len(vr.Errors) > 0
}

// Error implements the error interface if you want to treat ValidationResult
// as an error when it fails. This is optional but can be convenient.
func (vr ValidationResult) Error() string {
	if vr.Success {
		return ""
	}
	var b strings.Builder
	b.WriteString(fmt.Sprintf("[%s failed]\n", vr.Name))
	for _, e := range vr.Errors {
		b.WriteString(fmt.Sprintf(" - %v\n", e))
	}
	return b.String()
}
