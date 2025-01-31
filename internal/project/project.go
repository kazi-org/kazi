// project.go
//
// The core Project struct that merges domain (Contract), architecture (Architecture),
// config (Config), plus references to docs, logs, and chunking if needed.

package project

// Project is an in-memory representation of all project data.
type Project struct {
	// Domain
	Contract *Contract

	// Architecture
	Architecture *Architecture

	// Config
	Config *Config

	// Optional doc manager, ephemeral logs, chunk provider
	DocManager      DocManager
	EphemeralLogger EphemeralLog
	Chunker         ChunkProvider
}
