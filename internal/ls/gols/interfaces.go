// Package gols provides a Go Language Server Protocol client implementation.
package gols

import (
	"github.com/kazi-org/kazi/internal/ls/types"
)

// SymbolQuerier provides methods for querying workspace symbols.
type SymbolQuerier interface {
	// GetWorkspaceSymbols returns all symbols in the workspace that match the query.
	GetWorkspaceSymbols(query string) ([]types.WorkspaceSymbol, error)
	// GetSymbolDocumentation returns the documentation for the given symbol.
	GetSymbolDocumentation(filePath, symbolName string) (string, error)
	// GetSymbolDefinition returns the definition of the given symbol.
	GetSymbolDefinition(filePath, symbolName string) (*types.SymbolDefinition, error)
}

// ReferenceQuerier provides methods for finding symbol references.
type ReferenceQuerier interface {
	// GetReferences returns all references to the given symbol.
	GetReferences(filePath, symbolName string) ([]*types.Location, error)
	// GetSymbolLocation returns the location of a symbol in a file.
	GetSymbolLocation(filePath, symbolName string) (*types.Location, error)
}

// FileReader provides methods for reading file contents.
type FileReader interface {
	// GetFileContent returns the content of a file.
	GetFileContent(filePath string) (string, error)
}

// CodeChecker provides methods for validating Go code.
type CodeChecker interface {
	// CheckCode validates the given Go code and returns whether it's valid.
	// If not valid, returns false and an error message.
	CheckCode(code string) (bool, error)
}

// Closer provides a method for cleaning up resources.
type Closer interface {
	// Close cleans up any resources used by the client.
	Close() error
}

// LSPClient defines the interface for interacting with a language server.
type LSPClient interface {
	GetWorkspaceSymbols(query string) ([]types.WorkspaceSymbol, error)
	GetSymbolDocumentation(filePath, symbolName string) (string, error)
	GetSymbolDefinition(filePath, symbolName string) (*types.SymbolDefinition, error)
	GetSymbolLocation(filePath, symbolName string) (*types.Location, error)
	GetReferences(filePath, symbolName string) ([]*types.Location, error)
	GetFileContent(filePath string) (string, error)
	CheckCode(code string) (bool, error)
	Close() error
}
