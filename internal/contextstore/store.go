// Package contextstore provides functionality for maintaining and querying
// a code context store that tracks Go source code symbols and their relationships.
package contextstore

import (
	"context"
	"sync"
	"time"

	"github.com/kazi-org/kazi/internal/contextstore/scanner"
	"github.com/kazi-org/kazi/internal/contextstore/types"
	gols "github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/pkg/errors"
)

// Store provides the complete interface for managing code context.
type Store interface {
	// GetSymbol returns symbol information by name.
	// Returns nil if the symbol is not found.
	GetSymbol(name string) *types.SymbolContext

	// GetFile returns file information by path.
	// Returns nil if the file is not found.
	GetFile(path string) *types.FileContext

	// GetCodeContext returns the current snapshot of the code context.
	GetCodeContext() *types.CodeContext

	// BuildOrRefresh scans the workspace and updates the code context.
	// The context parameter is used to control the scan operation's lifetime.
	// Returns an error if the scan fails.
	BuildOrRefresh(ctx context.Context) error
}

// KaziContextStore implements the Store interface for managing code context.
type KaziContextStore struct {
	mu           sync.RWMutex
	codeCtx      *types.CodeContext
	workspace    string
	lastScan     int64
	scanInterval int64
	scanner      scanner.Scanner
}

// NewKaziContextStore creates a new store with default scan interval of 30 seconds.
func NewKaziContextStore(workspace string, lspClient gols.LSPClient) Store {
	config := scanner.Config{
		Workspace:    workspace,
		ScanInterval: 30,
		LSPClient:    lspClient,
	}

	return &KaziContextStore{
		codeCtx:      types.NewCodeContext(),
		workspace:    workspace,
		scanInterval: config.ScanInterval,
		scanner:      scanner.NewGoWorkspaceScanner(config),
	}
}

// GetCodeContext returns the current code context.
// This method is safe for concurrent access.
func (cs *KaziContextStore) GetCodeContext() *types.CodeContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx
}

// GetSymbol implements SymbolReader interface.
func (cs *KaziContextStore) GetSymbol(name string) *types.SymbolContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx.GetSymbol(name)
}

// GetFile implements FileReader interface.
func (cs *KaziContextStore) GetFile(path string) *types.FileContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx.GetFile(path)
}

// BuildOrRefresh scans the workspace and updates the code context.
// It will skip scanning if the last scan was performed within scanInterval seconds.
func (cs *KaziContextStore) BuildOrRefresh(ctx context.Context) error {
	// Quick check without lock
	now := time.Now().Unix()
	if now-cs.lastScan < cs.scanInterval {
		return nil
	}

	cs.mu.Lock()
	defer cs.mu.Unlock()

	// Check again with lock to avoid race condition
	if now-cs.lastScan < cs.scanInterval {
		return nil
	}

	// Use provided context for cancellation
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	newCtx, err := cs.scanner.Scan(ctx)
	if err != nil {
		return errors.Wrap(err, "failed to scan workspace")
	}

	cs.codeCtx = newCtx
	cs.lastScan = now
	return nil
}
