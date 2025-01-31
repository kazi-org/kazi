// llm_client.go
//
// An optional interface for calling the LLM. 
// The coordinator references this to get a patch from the user prompt + context.

package coordinator

import (
	"context"

	"github.com/yourorg/kazi/internal/patch"
)

// LLMClient represents a minimal interface for generating patch sets from an LLM.
type LLMClient interface {
	// GeneratePatch takes the final user prompt (which includes aggregated contexts) 
	// and returns a PatchSet for the coordinator to apply.
	GeneratePatch(ctx context.Context, prompt string) (*patch.PatchSet, error)
}
