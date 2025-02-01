package db

import "context"

// DB is an interface for storing text and retrieving topK matches by similarity.
type DB interface {
	StoreText(ctx context.Context, chunkID, text string) error
	QueryText(ctx context.Context, query string, topK int) ([]Result, error)
}

type Result struct {
	ChunkID string
	Text    string
	Score   float32
}
