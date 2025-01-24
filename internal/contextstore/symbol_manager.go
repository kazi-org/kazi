package contextstore

import (
    "fmt"
    "sort"
    "strings"
    "sync"
)

// SymbolManager interface
type SymbolManager interface {
    GetSymbolContext(filePath, symbolName string) (*SymbolContext, error)
    ExpandSymbolDetail(filePath, symbolName string) (string, error)
    FindRelevantContext(codeSnippet, userPrompt string) string
}

// symbolManager implements SymbolManager
type symbolManager struct {
    store *KaziContextStore
    mu    sync.RWMutex
}

func NewSymbolManager(store *KaziContextStore) SymbolManager {
    return &symbolManager{store: store}
}

func (sm *symbolManager) GetSymbolContext(filePath, symbolName string) (*SymbolContext, error) {
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

// ExpandSymbolDetail provides a string representation of docstrings, code lines, references
func (sm *symbolManager) ExpandSymbolDetail(filePath, symbolName string) (string, error) {
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

func (sm *symbolManager) FindRelevantContext(codeSnippet, userPrompt string) string {
    sm.mu.RLock()
    defer sm.mu.RUnlock()

    cc := sm.store.GetCodeContext()
    type snippetScore struct {
        sc    *SymbolContext
        score int
    }
    var allScores []snippetScore
    keywords := strings.Fields(strings.ToLower(userPrompt + " " + codeSnippet))

    // naive approach: partial scoring
    for _, fc := range cc.Files {
        for _, sym := range fc.Symbols {
            score := 0
            // check name
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

    // sort by score desc
    sort.Slice(allScores, func(i, j int) bool {
        return allScores[i].score > allScores[j].score
    })

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
