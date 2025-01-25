// Package symbol provides functionality for managing and querying code symbols.
package symbol

import (
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/kazi-org/kazi/internal/contextstore/types"
)

// Manager defines the interface for symbol management operations.
type Manager interface {
	// GetSymbolContext returns the context for a specific symbol in a file.
	GetSymbolContext(filePath, symbolName string) (*types.SymbolContext, error)

	// ExpandSymbolDetail returns a detailed string representation of a symbol.
	ExpandSymbolDetail(filePath, symbolName string) (string, error)

	// FindRelevantContext finds and returns relevant code context based on a code snippet and user prompt.
	FindRelevantContext(codeSnippet, userPrompt string) string
}

// manager implements the Manager interface.
type manager struct {
	store Store
	mu    sync.RWMutex
}

// Store defines the minimal interface required by the symbol manager.
type Store interface {
	GetCodeContext() *types.CodeContext
}

// New creates a new symbol manager instance.
func New(store Store) Manager {
	return &manager{store: store}
}

// GetSymbolContext implements Manager interface.
func (sm *manager) GetSymbolContext(filePath, symbolName string) (*types.SymbolContext, error) {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	cc := sm.store.GetCodeContext()
	fc, exists := cc.Files[filePath]
	if !exists {
		return nil, fmt.Errorf("file not found in code context: %s", filePath)
	}
	sc, ok := fc.Symbols[symbolName]
	if !ok {
		return nil, fmt.Errorf("symbol not found: %s in file %s", symbolName, filePath)
	}
	return sc, nil
}

// ExpandSymbolDetail implements Manager interface.
func (sm *manager) ExpandSymbolDetail(filePath, symbolName string) (string, error) {
	sc, err := sm.GetSymbolContext(filePath, symbolName)
	if err != nil {
		return "", err
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Symbol: %s (%s)\n", sc.Name, sc.Kind))
	if sc.DocString != "" {
		b.WriteString("Documentation:\n")
		b.WriteString(sc.DocString + "\n")
	}
	b.WriteString("Code:\n")
	for _, line := range sc.CodeLines {
		b.WriteString(line + "\n")
	}
	if len(sc.References) > 0 {
		b.WriteString("References:\n")
		for _, r := range sc.References {
			b.WriteString("- " + r + "\n")
		}
	}
	return b.String(), nil
}

// FindRelevantContext implements Manager interface.
func (sm *manager) FindRelevantContext(codeSnippet, userPrompt string) string {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	cc := sm.store.GetCodeContext()
	type snippetScore struct {
		sc    *types.SymbolContext
		score int
	}
	var allScores []snippetScore
	keywords := strings.Fields(strings.ToLower(userPrompt + " " + codeSnippet))

	// Score each symbol based on keyword matches
	for _, fc := range cc.Files {
		for _, sym := range fc.Symbols {
			score := 0
			// Check name
			for _, kw := range keywords {
				if strings.Contains(strings.ToLower(sym.Name), kw) {
					score += 5
				}
				if strings.Contains(strings.ToLower(sym.DocString), kw) {
					score += 3
				}
				for _, line := range sym.CodeLines {
					if strings.Contains(strings.ToLower(line), kw) {
						score += 2
					}
				}
			}
			if score > 0 {
				allScores = append(allScores, snippetScore{sc: sym, score: score})
			}
		}
	}

	// Sort by score in descending order
	sort.Slice(allScores, func(i, j int) bool {
		return allScores[i].score > allScores[j].score
	})

	// Build the result string with the top 5 matches
	var builder strings.Builder
	for i, scored := range allScores {
		if i >= 5 {
			break
		}
		sc := scored.sc
		builder.WriteString(fmt.Sprintf("=== %s (%s) ===\n", sc.Name, sc.Kind))
		if sc.DocString != "" {
			builder.WriteString(sc.DocString + "\n")
		}
		for _, line := range sc.CodeLines {
			builder.WriteString(line + "\n")
		}
		builder.WriteString("\n")
	}

	return builder.String()
}
