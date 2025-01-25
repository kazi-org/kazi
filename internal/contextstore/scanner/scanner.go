// Package scanner provides functionality for scanning Go workspaces
// and extracting code context information.
package scanner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/kazi-org/kazi/internal/contextstore/format"
	"github.com/kazi-org/kazi/internal/contextstore/types"
	gols "github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/pkg/errors"
)

// Scanner defines the interface for code scanning operations.
type Scanner interface {
	// Scan performs a workspace scan and returns a new CodeContext.
	// The context parameter is used to control the scan operation's lifetime.
	Scan(ctx context.Context) (*types.CodeContext, error)
}

// Config holds configuration for workspace scanning.
type Config struct {
	// Workspace is the root directory to scan
	Workspace string
	// ScanInterval is the minimum time between scans in seconds
	ScanInterval int64
	// LSPClient provides language server protocol functionality
	LSPClient gols.LSPClient
}

// GoWorkspaceScanner implements Scanner for Go workspaces.
type GoWorkspaceScanner struct {
	config Config
}

// NewGoWorkspaceScanner creates a new scanner with the given configuration.
func NewGoWorkspaceScanner(config Config) Scanner {
	return &GoWorkspaceScanner{config: config}
}

// Scan implements the Scanner interface.
func (ws *GoWorkspaceScanner) Scan(ctx context.Context) (*types.CodeContext, error) {
	codeCtx := types.NewCodeContext()

	err := filepath.Walk(ws.config.Workspace, func(path string, info os.FileInfo, err error) error {
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
				relPath, err := filepath.Rel(ws.config.Workspace, path)
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
func (ws *GoWorkspaceScanner) processGoFile(ctx context.Context, path string) (*types.FileContext, error) {
	relPath, err := filepath.Rel(ws.config.Workspace, path)
	if err != nil {
		return nil, errors.Wrap(err, "get relative path")
	}

	content, err := ws.config.LSPClient.GetFileContent(relPath)
	if err != nil {
		return nil, errors.Wrap(err, "read file")
	}

	if ok, errMsg := ws.config.LSPClient.CheckCode(content); !ok {
		return nil, fmt.Errorf("invalid Go code: %s", errMsg)
	}

	pkgName := format.ExtractPackageName(content)
	symbols, err := ws.config.LSPClient.GetWorkspaceSymbols(filepath.Base(relPath))
	if err != nil {
		return nil, errors.Wrap(err, "get symbols")
	}

	fileCtx := types.NewFileContext(relPath)

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
func (ws *GoWorkspaceScanner) buildSymbolContext(ctx context.Context, sym *gols.WorkspaceSymbol, pkgName, filePath string) (*types.SymbolContext, error) {
	doc, err := ws.config.LSPClient.GetSymbolDocumentation(filepath.Base(filePath), sym.Name)
	if err != nil {
		return nil, errors.Wrap(err, "get documentation")
	}

	def, err := ws.config.LSPClient.GetSymbolDefinition(filepath.Base(filePath), sym.Name)
	if err != nil {
		return nil, errors.Wrap(err, "get definition")
	}

	refs, err := ws.config.LSPClient.GetReferences(sym.Name)
	if err != nil {
		return nil, errors.Wrap(err, "get references")
	}

	loc, err := ws.config.LSPClient.GetSymbolLocation(filepath.Base(filePath), sym.Name)
	if err != nil {
		loc = sym.Location // fallback to basic location
	}

	return &types.SymbolContext{
		Name:       sym.Name,
		Kind:       types.SymbolKind(sym.Kind),
		DocString:  doc,
		StartLine:  sym.Location.Range.Start.Line + 1,
		EndLine:    sym.Location.Range.End.Line + 1,
		Signature:  def.Signature,
		Exported:   format.IsExported(sym.Name),
		Package:    pkgName,
		References: refs,
		Location:   loc,
		TypeInfo:   def.Kind,
	}, nil
}
