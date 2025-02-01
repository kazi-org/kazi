package db

import "context"

// DB is the interface for storing text + retrieving topK relevant results 
// via embeddings-based similarity. Formerly embeddb, we can use e.g. chromem-go.

type DB interface {
	StoreText(ctx context.Context, chunkID, text string) error
	QueryText(ctx context.Context, query string, topK int) ([]Result, error)
}

type Result struct {
	ChunkID string
	Text    string
	Score   float32
}
