// Package symbol provides functionality for managing code symbols.
package symbol

import (
	"strings"

	"github.com/kazi-org/kazi/internal/contextstore/types"
)

// Manager provides operations for managing code symbols.
type Manager interface {
	// GetSymbolByName returns a symbol by its name.
	GetSymbolByName(name string) *types.SymbolContext
	// GetSymbolsByKind returns all symbols of a given kind.
	GetSymbolsByKind(kind string) []*types.SymbolContext
	// GetSymbolsByFile returns all symbols in a given file.
	GetSymbolsByFile(filePath string) []*types.SymbolContext
	// GetSymbolsByPattern returns all symbols matching a pattern.
	GetSymbolsByPattern(pattern string) []*types.SymbolContext
}

// Store represents a store that can be queried for symbols.
type Store interface {
	GetSymbol(name string) *types.SymbolContext
	GetFile(path string) *types.FileContext
	GetCodeContext() *types.CodeContext
}

// DefaultManager implements Manager using a Store.
type DefaultManager struct {
	store Store
}

// NewManager creates a new DefaultManager with the given store.
func NewManager(store Store) Manager {
	return &DefaultManager{store: store}
}

// GetSymbolByName returns a symbol by its name.
func (m *DefaultManager) GetSymbolByName(name string) *types.SymbolContext {
	return m.store.GetSymbol(name)
}

// GetSymbolsByKind returns all symbols of a given kind.
func (m *DefaultManager) GetSymbolsByKind(kind string) []*types.SymbolContext {
	var symbols []*types.SymbolContext
	ctx := m.store.GetCodeContext()
	if ctx == nil {
		return nil
	}

	for _, file := range ctx.Files {
		for _, sym := range file.Symbols {
			if sym.Kind == kind {
				symbols = append(symbols, sym)
			}
		}
	}
	return symbols
}

// GetSymbolsByFile returns all symbols in a given file.
func (m *DefaultManager) GetSymbolsByFile(filePath string) []*types.SymbolContext {
	var symbols []*types.SymbolContext
	file := m.store.GetFile(filePath)
	if file == nil {
		return nil
	}

	for _, sym := range file.Symbols {
		symbols = append(symbols, sym)
	}
	return symbols
}

// GetSymbolsByPattern returns all symbols matching a pattern.
func (m *DefaultManager) GetSymbolsByPattern(pattern string) []*types.SymbolContext {
	var symbols []*types.SymbolContext
	ctx := m.store.GetCodeContext()
	if ctx == nil {
		return nil
	}

	for _, file := range ctx.Files {
		for _, sym := range file.Symbols {
			if strings.Contains(sym.Name, pattern) {
				symbols = append(symbols, sym)
			}
		}
	}
	return symbols
}
