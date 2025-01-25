package contextstore

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// KaziContextStore is the main container that builds/refreshes the CodeContext
type KaziContextStore struct {
	mu           sync.RWMutex
	codeCtx      *CodeContext
	workspace    string
	lastScan     int64
	scanInterval int64
}

// NewKaziContextStore creates a new store with default scan interval
func NewKaziContextStore(workspace string) *KaziContextStore {
	return &KaziContextStore{
		codeCtx: &CodeContext{
			Files: make(map[string]*FileContext),
		},
		workspace:    workspace,
		scanInterval: 30,
	}
}

// BuildOrRefresh scans the workspace, ignoring .git.
// Minimally populates FileContext + SymbolContext for each .go file
func (cs *KaziContextStore) BuildOrRefresh() error {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	now := time.Now().Unix()
	if now-cs.lastScan < cs.scanInterval {
		return nil // skip
	}
	codeCtx := &CodeContext{Files: make(map[string]*FileContext)}

	err := filepath.Walk(cs.workspace, func(path string, info os.FileInfo, werr error) error {
		if werr != nil {
			return werr
		}
		if info.IsDir() {
			if strings.Contains(path, ".git") {
				return filepath.SkipDir
			}
			return nil
		}
		rel, _ := filepath.Rel(cs.workspace, path)

		// skip non-go or .gitignore
		if !strings.HasSuffix(rel, ".go") || strings.HasSuffix(rel, ".gitignore") {
			return nil
		}

		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		lines := strings.Split(string(data), "\n")
		fc := &FileContext{
			FilePath: rel,
			Imports:  []string{},
			Symbols:  make(map[string]*SymbolContext),
		}

		// Single symbol approach: the entire file as SymbolContext
		sc := &SymbolContext{
			Name:       filepath.Base(rel),
			Kind:       "file",
			DocString:  fmt.Sprintf("Entire file: %s", rel),
			CodeLines:  shortSnippet(lines),
			StartLine:  1,
			EndLine:    len(lines),
			References: []string{},
			Rank:       0, // we'll compute if needed
		}
		fc.Symbols[sc.Name] = sc
		codeCtx.Files[rel] = fc
		return nil
	})
	if err != nil {
		return fmt.Errorf("walk workspace: %w", err)
	}

	cs.codeCtx = codeCtx
	cs.lastScan = now
	return nil
}

// shortSnippet is a minimal approach returning up to 20 lines
func shortSnippet(lines []string) []string {
	max := 20
	if len(lines) <= max {
		return lines
	}
	return lines[:max]
}

// GetCodeContext returns the read-only CodeContext
func (cs *KaziContextStore) GetCodeContext() *CodeContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx
}
