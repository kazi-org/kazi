// Package scanner provides functionality for scanning Go source code.
package scanner

import (
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/kazi-org/kazi/internal/contextstore/types"
	lstypes "github.com/kazi-org/kazi/internal/ls/types"
	"github.com/pkg/errors"
	"golang.org/x/sync/errgroup"
)

// Scanner defines the interface for scanning Go source code.
type Scanner interface {
	// Scan scans the workspace and returns a code context.
	Scan(ctx context.Context) (*types.CodeContext, error)
}

// Config holds configuration for the scanner.
type Config struct {
	// Workspace is the root directory to scan
	Workspace string
	// ScanInterval is the minimum time between scans in seconds
	ScanInterval int64
	// MaxConcurrentFiles is the maximum number of files to process concurrently
	MaxConcurrentFiles int
	// LSPClient provides language server protocol functionality
	LSPClient interface {
		GetWorkspaceSymbols(query string) ([]lstypes.WorkspaceSymbol, error)
		GetSymbolDocumentation(filePath, symbolName string) (string, error)
		GetReferences(filePath, symbolName string) ([]*lstypes.Location, error)
		GetSymbolDefinition(filePath, symbolName string) (*lstypes.SymbolDefinition, error)
		GetFileContent(filePath string) (string, error)
	}
}

// astCacheEntry represents a cached AST with its modification time
type astCacheEntry struct {
	file    *ast.File
	modTime int64
}

// symbolVisitor implements ast.Visitor for efficient symbol collection
type symbolVisitor struct {
	fset    *token.FileSet
	fileCtx *types.FileContext
	relPath string
	inConst bool // tracks if we're inside a const block
}

func (v *symbolVisitor) Visit(n ast.Node) ast.Visitor {
	if n == nil {
		return nil
	}

	switch node := n.(type) {
	case *ast.GenDecl:
		wasConst := v.inConst
		v.inConst = node.Tok == token.CONST
		defer func() { v.inConst = wasConst }()
		return v

	case *ast.FuncDecl:
		v.addFunction(node)
		return nil // skip traversing function body

	case *ast.TypeSpec:
		v.addType(node)
		return nil

	case *ast.ValueSpec:
		v.addValues(node)
		return nil
	}

	return v
}

func (v *symbolVisitor) addFunction(node *ast.FuncDecl) {
	pos := v.fset.Position(node.Pos())
	end := v.fset.Position(node.End())
	v.fileCtx.Symbols[node.Name.Name] = &types.SymbolContext{
		Name:      node.Name.Name,
		Kind:      string(types.KindFunction),
		DocString: node.Doc.Text(),
		Location:  v.createLocation(pos, end),
	}
}

func (v *symbolVisitor) addType(node *ast.TypeSpec) {
	pos := v.fset.Position(node.Pos())
	end := v.fset.Position(node.End())
	v.fileCtx.Symbols[node.Name.Name] = &types.SymbolContext{
		Name:      node.Name.Name,
		Kind:      string(types.KindType),
		DocString: node.Doc.Text(),
		Location:  v.createLocation(pos, end),
	}
}

func (v *symbolVisitor) addValues(node *ast.ValueSpec) {
	for _, name := range node.Names {
		pos := v.fset.Position(name.Pos())
		end := v.fset.Position(name.End())
		kind := string(types.KindVariable)
		if v.inConst {
			kind = string(types.KindConstant)
		}
		v.fileCtx.Symbols[name.Name] = &types.SymbolContext{
			Name:      name.Name,
			Kind:      kind,
			DocString: node.Doc.Text(),
			Location:  v.createLocation(pos, end),
		}
	}
}

func (v *symbolVisitor) createLocation(pos, end token.Position) *lstypes.Location {
	return &lstypes.Location{
		URI: v.relPath,
		Range: lstypes.Range{
			Start: lstypes.Position{
				Line:      pos.Line - 1,
				Character: pos.Column - 1,
			},
			End: lstypes.Position{
				Line:      end.Line - 1,
				Character: end.Column - 1,
			},
		},
	}
}

// GoWorkspaceScanner implements Scanner for Go workspaces.
type GoWorkspaceScanner struct {
	config   Config
	fset     *token.FileSet
	astCache sync.Map // map[string]astCacheEntry
}

// NewGoWorkspaceScanner creates a new scanner for Go workspaces.
func NewGoWorkspaceScanner(config Config) Scanner {
	if config.MaxConcurrentFiles <= 0 {
		config.MaxConcurrentFiles = 10 // default value
	}
	return &GoWorkspaceScanner{
		config: config,
		fset:   token.NewFileSet(),
	}
}

// getOrParseFile gets the AST from cache or parses the file if needed
func (s *GoWorkspaceScanner) getOrParseFile(path string) (*ast.File, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}

	if entry, ok := s.astCache.Load(path); ok {
		cached := entry.(astCacheEntry)
		if cached.modTime == info.ModTime().UnixNano() {
			return cached.file, nil
		}
	}

	f, err := parser.ParseFile(s.fset, path, nil, parser.ParseComments|parser.ParseComments)
	if err != nil {
		return nil, err
	}

	s.astCache.Store(path, astCacheEntry{
		file:    f,
		modTime: info.ModTime().UnixNano(),
	})

	return f, nil
}

// processFile processes a single file and returns its FileContext
func (s *GoWorkspaceScanner) processFile(ctx context.Context, path string) (*types.FileContext, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	relPath, err := filepath.Rel(s.config.Workspace, path)
	if err != nil {
		return nil, errors.Wrap(err, "get relative path")
	}

	f, err := s.getOrParseFile(path)
	if err != nil {
		return nil, errors.Wrap(err, "parse file")
	}

	fileCtx := &types.FileContext{
		FilePath: relPath,
		Symbols:  make(map[string]*types.SymbolContext),
	}

	// Use custom visitor for more efficient traversal
	visitor := &symbolVisitor{
		fset:    s.fset,
		fileCtx: fileCtx,
		relPath: relPath,
	}
	ast.Walk(visitor, f)

	return fileCtx, nil
}

// Scan implements Scanner.Scan.
func (s *GoWorkspaceScanner) Scan(ctx context.Context) (*types.CodeContext, error) {
	codeCtx := types.NewCodeContext()
	var filePaths []string

	// First, collect all Go files
	err := filepath.Walk(s.config.Workspace, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(path, ".go") {
			filePaths = append(filePaths, path)
		}
		return nil
	})
	if err != nil {
		return nil, errors.Wrap(err, "walk workspace")
	}

	// Process files concurrently using errgroup
	g, ctx := errgroup.WithContext(ctx)
	filesChan := make(chan string)

	// Start worker pool
	for i := 0; i < s.config.MaxConcurrentFiles; i++ {
		g.Go(func() error {
			for path := range filesChan {
				fileCtx, err := s.processFile(ctx, path)
				if err != nil {
					return err
				}

				// Thread-safe map update
				codeCtx.Files[fileCtx.FilePath] = fileCtx
			}
			return nil
		})
	}

	// Feed files to workers
	go func() {
		defer close(filesChan)
		for _, path := range filePaths {
			select {
			case <-ctx.Done():
				return
			case filesChan <- path:
			}
		}
	}()

	if err := g.Wait(); err != nil {
		return nil, errors.Wrap(err, "process files")
	}

	return codeCtx, nil
}
