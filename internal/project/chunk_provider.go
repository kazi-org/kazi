// chunk_provider.go
//
// Demonstrates how you might retrieve code slices or line-based segments
// for the LLM, potentially using concurrency. This is optional; you can
// also let an LSP do chunking or code scanning.

package project

import (
	"context"
)

// CodeChunk contains the extracted code snippet plus metadata.
type CodeChunk struct {
	FilePath string
	StartLine int
	EndLine   int
	Content   string
}

// ChunkProvider is a specialized interface for retrieving code in chunks.
type ChunkProvider interface {
	// ProvideChunks splits or extracts code segments for a given module or file,
	// respecting a max token limit. It can spawn goroutines for large files.
	ProvideChunks(ctx context.Context, moduleOrFile string, maxTokens int) ([]CodeChunk, error)
}
