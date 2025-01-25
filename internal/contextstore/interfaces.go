// Package contextstore provides functionality for maintaining and querying
// a code context store that tracks Go source code symbols and their relationships.
package contextstore

import (
	"context"

	"github.com/kazi-org/kazi/internal/contextstore/types"
)

// SymbolReader provides read-only access to symbol information.
type SymbolReader interface {
	// GetSymbol returns symbol information by name.
	// Returns nil if the symbol is not found.
	GetSymbol(name string) *types.SymbolContext
}

// FileReader provides read-only access to file information.
type FileReader interface {
	// GetFile returns file information by path.
	// Returns nil if the file is not found.
	GetFile(path string) *types.FileContext
}

// ContextReader provides read-only access to the entire code context.
type ContextReader interface {
	// GetCodeContext returns the current snapshot of the code context.
	GetCodeContext() *types.CodeContext
}

// ContextBuilder handles the building and refreshing of code context.
type ContextBuilder interface {
	// BuildOrRefresh scans the workspace and updates the code context.
	// The context parameter is used to control the scan operation's lifetime.
	// Returns an error if the scan fails.
	BuildOrRefresh(ctx context.Context) error
}

// Store combines all the reader and builder interfaces for managing code context.
// It provides a complete interface for code context management.
type Store interface {
	SymbolReader
	FileReader
	ContextReader
	ContextBuilder
}
