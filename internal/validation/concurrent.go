// concurrent.go
//
// Demonstrates a pipeline aggregator that runs multiple checks concurrently.

package validation

import (
	"context"
	"sync"
)

// ConcurrentPipeline implements Pipeline, running multiple checks in parallel,
// then aggregates results into a single final ValidationResult.
type ConcurrentPipeline struct {
	Checks []Check
	NameVal string // Optional name for this pipeline aggregator
}

// ValidateAll runs the checks concurrently, collecting success/fail states.
func (cp *ConcurrentPipeline) ValidateAll(ctx context.Context) ValidationResult {
	var finalRes ValidationResult
	if cp.NameVal == "" {
		finalRes.Name = "ConcurrentPipeline"
	} else {
		finalRes.Name = cp.NameVal
	}
	finalRes.Success = true // assume success unless we get errors

	resultsChan := make(chan ValidationResult, len(cp.Checks))
	var wg sync.WaitGroup

	for _, ch := range cp.Checks {
		wg.Add(1)
		go func(c Check) {
			defer wg.Done()
			res := c.Run(ctx)
			resultsChan <- res
		}(ch)
	}

	wg.Wait()
	close(resultsChan)

	var errorsFound []error
	for r := range resultsChan {
		// If a single check fails, we set pipeline success to false
		if !r.Success {
			finalRes.Success = false
			errorsFound = append(errorsFound, r.Errors...)
		}
	}

	finalRes.Errors = errorsFound
	return finalRes
}

// NewConcurrentPipeline is a convenience constructor for concurrency-based aggregator.
func NewConcurrentPipeline(name string, checks ...Check) Pipeline {
	return &ConcurrentPipeline{
		NameVal: name,
		Checks:  checks,
	}
}
