// Package types provides the core data structures for the code context store.
package types

import gols "github.com/kazi-org/kazi/internal/ls/gols"

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
