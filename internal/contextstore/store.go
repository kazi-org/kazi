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

// StoreConfig holds configuration for the context store.
type StoreConfig struct {
	// Workspace is the root directory to scan
	Workspace string
	// ScanInterval is the minimum time between scans in seconds
	ScanInterval int64
	// LSPClient provides language server protocol functionality
	LSPClient gols.LSPClient
}

// KaziContextStore implements the Store interface for managing code context.
// It provides thread-safe access to code context information and handles
// periodic workspace scanning.
type KaziContextStore struct {
	mu           sync.RWMutex
	codeCtx      *types.CodeContext
	workspace    string
	lastScan     int64
	scanInterval int64
	scanner      scanner.Scanner
}

// NewKaziContextStore creates a new store with the given configuration.
// It initializes the store with an empty code context and sets up the scanner
// with the provided configuration.
func NewKaziContextStore(config StoreConfig) Store {
	scannerConfig := scanner.Config{
		Workspace:    config.Workspace,
		ScanInterval: config.ScanInterval,
		LSPClient:    config.LSPClient,
	}

	return &KaziContextStore{
		codeCtx:      types.NewCodeContext(),
		workspace:    config.Workspace,
		scanInterval: config.ScanInterval,
		scanner:      scanner.NewGoWorkspaceScanner(scannerConfig),
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
// It returns symbol information by name, or nil if not found.
func (cs *KaziContextStore) GetSymbol(name string) *types.SymbolContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx.GetSymbol(name)
}

// GetFile implements FileReader interface.
// It returns file information by path, or nil if not found.
func (cs *KaziContextStore) GetFile(path string) *types.FileContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx.GetFile(path)
}

// BuildOrRefresh scans the workspace and updates the code context.
// It will skip scanning if the last scan was performed within scanInterval seconds.
// This method is safe for concurrent access.
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
