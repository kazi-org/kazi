// Package contextstore provides functionality for maintaining and querying
// a code context store that tracks Go source code symbols and their relationships.
package contextstore

import (
	"context"

	gols "github.com/kazi-org/kazi/internal/ls/gols"
)

// SymbolReader provides read-only access to symbol information.
type SymbolReader interface {
	// GetSymbol returns symbol information by name.
	// Returns nil if the symbol is not found.
	GetSymbol(name string) *SymbolContext
}

// FileReader provides read-only access to file information.
type FileReader interface {
	// GetFile returns file information by path.
	// Returns nil if the file is not found.
	GetFile(path string) *FileContext
}

// ContextReader provides read-only access to code context information.
type ContextReader interface {
	SymbolReader
	FileReader
	// GetCodeContext returns the current snapshot of the code context.
	GetCodeContext() *CodeContext
}

// ContextBuilder handles the building and refreshing of code context.
type ContextBuilder interface {
	// BuildOrRefresh scans the workspace and updates the code context.
	// The context parameter is used to control the scan operation's lifetime.
	// Returns an error if the scan fails.
	BuildOrRefresh(ctx context.Context) error
}

// Store combines the reader and builder interfaces for managing code context.
type Store interface {
	ContextReader
	ContextBuilder
}

// CodeContext represents the entire workspace's code context.
// It provides a snapshot of all files and their symbols at a point in time.
type CodeContext struct {
	// Files maps relative file paths to their corresponding FileContext.
	Files map[string]*FileContext
}

// FileContext represents a single file's context including its symbols and imports.
type FileContext struct {
	// FilePath is the relative path of the file in the workspace
	FilePath string

	// Imports contains the list of import paths used in the file
	Imports []string

	// Symbols maps symbol names to their detailed context information
	Symbols map[string]*SymbolContext
}

// SymbolKind represents the type of a symbol (function, type, constant, etc.)
type SymbolKind string

const (
	// KindFunction represents a function symbol
	KindFunction SymbolKind = "function"
	// KindType represents a type symbol
	KindType SymbolKind = "type"
	// KindConstant represents a constant symbol
	KindConstant SymbolKind = "constant"
	// KindVariable represents a variable symbol
	KindVariable SymbolKind = "variable"
)

// SymbolContext represents detailed information about a single symbol
// (function, type, constant, or variable).
type SymbolContext struct {
	// Name is the identifier of the symbol
	Name string

	// Kind indicates the symbol type
	Kind SymbolKind

	// DocString contains the documentation comments for the symbol
	DocString string

	// CodeLines contains the actual source code lines
	CodeLines []string

	// StartLine is the 1-based line number where the symbol definition starts
	StartLine int

	// EndLine is the 1-based line number where the symbol definition ends (inclusive)
	EndLine int

	// Signature contains the function signature or type definition
	Signature string

	// Exported indicates whether the symbol is exported (public)
	Exported bool

	// Package is the name of the package containing the symbol
	Package string

	// References lists the files that reference this symbol
	References []string

	// Location provides precise symbol location information
	Location gols.Location

	// TypeInfo contains type information for variables and constants
	TypeInfo string

	// Methods lists the methods available on this type (if it's a type)
	Methods []string

	// Implements lists the interfaces this type implements (if it's a type)
	Implements []string
}

// NewCodeContext creates a new empty CodeContext.
func NewCodeContext() *CodeContext {
	return &CodeContext{
		Files: make(map[string]*FileContext),
	}
}

// NewFileContext creates a new FileContext with the given path.
func NewFileContext(path string) *FileContext {
	return &FileContext{
		FilePath: path,
		Imports:  make([]string, 0, 8), // Pre-allocate space for common case
		Symbols:  make(map[string]*SymbolContext),
	}
}

// GetSymbol returns the symbol context for the given name.
// Returns nil if the symbol is not found.
func (c *CodeContext) GetSymbol(name string) *SymbolContext {
	for _, file := range c.Files {
		if sym, ok := file.Symbols[name]; ok {
			return sym
		}
	}
	return nil
}

// GetFile returns the file context for the given path.
// Returns nil if the file is not found.
func (c *CodeContext) GetFile(path string) *FileContext {
	return c.Files[path]
}
