package lsp

import "github.com/kazi-org/kazi/internal/ls/types"

// SymbolQuerier handles workspace symbol-related operations
type SymbolQuerier interface {
	// GetWorkspaceSymbols returns all symbols matching the query in the workspace
	GetWorkspaceSymbols(query string) ([]types.WorkspaceSymbol, error)

	// GetSymbolDocumentation returns documentation for a symbol at the given URI
	GetSymbolDocumentation(uri string, symbolName string) (string, error)

	// GetReferences returns all references to the given symbol
	GetReferences(symbol string) ([]string, error)

	// GetSymbolDefinition returns the definition location of a symbol
	GetSymbolDefinition(filePath, symbolName string) (*types.SymbolDefinition, error)

	// GetSymbolLocation returns the location of a symbol in a file
	GetSymbolLocation(filePath, symbolName string) (types.Location, error)
}

// FileReader handles file content operations
type FileReader interface {
	// GetFileContent returns the content of a file at the given path
	GetFileContent(filePath string) (string, error)
}

// CodeChecker handles code validation operations
type CodeChecker interface {
	// CheckCode validates the given code and returns validation status and message
	CheckCode(code string) (bool, string)
}

// Closer handles cleanup operations
type Closer interface {
	// Close cleans up resources and shuts down the client
	Close() error
}

// LSPClient combines all LSP client capabilities
type LSPClient interface {
	SymbolQuerier
	FileReader
	CodeChecker
	Closer
}
