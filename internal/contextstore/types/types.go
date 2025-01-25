// Package types provides the core data structures for the code context store.
package types

import (
	"github.com/kazi-org/kazi/internal/ls/types"
)

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

// CodeContext represents the entire code context for a workspace.
type CodeContext struct {
	Files map[string]*FileContext // Map of file paths to file contexts
}

// FileContext represents the context for a single file.
type FileContext struct {
	FilePath string                    // Path to the file
	Content  string                    // File content
	Symbols  map[string]*SymbolContext // Map of symbol names to symbol contexts
}

// SymbolContext represents a code symbol and its metadata.
type SymbolContext struct {
	Name       string
	Kind       string
	DocString  string
	Signature  string
	Location   *types.Location
	References []*types.Location
}

// NewCodeContext creates a new empty code context.
func NewCodeContext() *CodeContext {
	return &CodeContext{
		Files: make(map[string]*FileContext),
	}
}

// GetSymbol returns a symbol by name from any file in the context.
func (c *CodeContext) GetSymbol(name string) *SymbolContext {
	for _, file := range c.Files {
		if sym, ok := file.Symbols[name]; ok {
			return sym
		}
	}
	return nil
}

// GetFile returns a file context by path.
func (c *CodeContext) GetFile(path string) *FileContext {
	return c.Files[path]
}
