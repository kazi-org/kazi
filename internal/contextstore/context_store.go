package contextstore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/kazi-org/kazi/internal/contextstore/format"
	gols "github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/pkg/errors"
)

// codeScanner is the interface for code scanning operations.
type codeScanner interface {
	// scan performs a workspace scan and returns a new CodeContext.
	scan(ctx context.Context) (*CodeContext, error)
}

// scannerConfig holds configuration for workspace scanning.
type scannerConfig struct {
	// workspace is the root directory to scan
	workspace string
	// scanInterval is the minimum time between scans in seconds
	scanInterval int64
	// lspClient provides language server protocol functionality
	lspClient gols.LSPClient
}

// goWorkspaceScanner handles the scanning of Go workspace files.
type goWorkspaceScanner struct {
	config scannerConfig
}

// KaziContextStore implements the Store interface for managing code context.
type KaziContextStore struct {
	mu           sync.RWMutex
	codeCtx      *CodeContext
	workspace    string
	lastScan     int64
	scanInterval int64
	scanner      codeScanner
}

// NewKaziContextStore creates a new store with default scan interval of 30 seconds.
func NewKaziContextStore(workspace string, lspClient gols.LSPClient) Store {
	config := scannerConfig{
		workspace:    workspace,
		scanInterval: 30,
		lspClient:    lspClient,
	}

	return &KaziContextStore{
		codeCtx:      NewCodeContext(),
		workspace:    workspace,
		scanInterval: config.scanInterval,
		scanner:      newGoWorkspaceScanner(config),
	}
}

// newGoWorkspaceScanner creates a new scanner with the given configuration.
func newGoWorkspaceScanner(config scannerConfig) codeScanner {
	return &goWorkspaceScanner{config: config}
}

// GetCodeContext returns the current code context.
// This method is safe for concurrent access.
func (cs *KaziContextStore) GetCodeContext() *CodeContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx
}

// GetSymbol implements SymbolReader interface.
func (cs *KaziContextStore) GetSymbol(name string) *SymbolContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx.GetSymbol(name)
}

// GetFile implements FileReader interface.
func (cs *KaziContextStore) GetFile(path string) *FileContext {
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

	newCtx, err := cs.scanner.scan(ctx)
	if err != nil {
		return errors.Wrap(err, "failed to scan workspace")
	}

	cs.codeCtx = newCtx
	cs.lastScan = now
	return nil
}

// scan performs a full workspace scan and returns a new CodeContext.
func (ws *goWorkspaceScanner) scan(ctx context.Context) (*CodeContext, error) {
	codeCtx := NewCodeContext()

	err := filepath.Walk(ws.config.workspace, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return errors.Wrap(err, "walk error")
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		if info.Name() == ".git" {
			return filepath.SkipDir
		}

		if !info.IsDir() && strings.HasSuffix(path, ".go") {
			fileCtx, err := ws.processGoFile(ctx, path)
			if err != nil {
				return errors.Wrapf(err, "process file %s", path)
			}
			if fileCtx != nil {
				relPath, err := filepath.Rel(ws.config.workspace, path)
				if err != nil {
					return errors.Wrap(err, "get relative path")
				}
				codeCtx.Files[relPath] = fileCtx
			}
		}

		return nil
	})

	if err != nil {
		return nil, errors.Wrap(err, "walk workspace")
	}

	return codeCtx, nil
}

// processGoFile analyzes a single Go file and returns its FileContext.
func (ws *goWorkspaceScanner) processGoFile(ctx context.Context, path string) (*FileContext, error) {
	relPath, err := filepath.Rel(ws.config.workspace, path)
	if err != nil {
		return nil, errors.Wrap(err, "get relative path")
	}

	content, err := ws.config.lspClient.GetFileContent(relPath)
	if err != nil {
		return nil, errors.Wrap(err, "read file")
	}

	if ok, errMsg := ws.config.lspClient.CheckCode(content); !ok {
		return nil, fmt.Errorf("invalid Go code: %s", errMsg)
	}

	pkgName := format.ExtractPackageName(content)
	symbols, err := ws.config.lspClient.GetWorkspaceSymbols(filepath.Base(relPath))
	if err != nil {
		return nil, errors.Wrap(err, "get symbols")
	}

	fileCtx := NewFileContext(relPath)

	for _, sym := range symbols {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		if filepath.Base(sym.Location.URI) != filepath.Base(path) {
			continue
		}

		symCtx, err := ws.buildSymbolContext(ctx, &sym, pkgName, relPath)
		if err != nil {
			// Log error but continue processing other symbols
			fmt.Printf("Warning: failed to process symbol %s: %v\n", sym.Name, err)
			continue
		}

		fileCtx.Symbols[sym.Name] = symCtx
	}

	return fileCtx, nil
}

// buildSymbolContext creates a SymbolContext for a single symbol.
func (ws *goWorkspaceScanner) buildSymbolContext(ctx context.Context, sym *gols.WorkspaceSymbol, pkgName, filePath string) (*SymbolContext, error) {
	doc, err := ws.config.lspClient.GetSymbolDocumentation(filepath.Base(filePath), sym.Name)
	if err != nil {
		return nil, errors.Wrap(err, "get documentation")
	}

	def, err := ws.config.lspClient.GetSymbolDefinition(filepath.Base(filePath), sym.Name)
	if err != nil {
		return nil, errors.Wrap(err, "get definition")
	}

	refs, err := ws.config.lspClient.GetReferences(sym.Name)
	if err != nil {
		return nil, errors.Wrap(err, "get references")
	}

	loc, err := ws.config.lspClient.GetSymbolLocation(filepath.Base(filePath), sym.Name)
	if err != nil {
		loc = sym.Location // fallback to basic location
	}

	symCtx := &SymbolContext{
		Name:       sym.Name,
		Kind:       SymbolKind(sym.Kind),
		DocString:  doc,
		StartLine:  sym.Location.Range.Start.Line + 1,
		EndLine:    sym.Location.Range.End.Line + 1,
		Signature:  def.Signature,
		Exported:   format.IsExported(sym.Name),
		Package:    pkgName,
		References: refs,
		Location:   loc,
		TypeInfo:   def.Kind,
	}

	if symCtx.Kind == KindType {
		symCtx.Methods = format.ExtractMethodSet(def)
		symCtx.Implements = format.ExtractImplementedInterfaces(def)
	}

	return symCtx, nil
}
