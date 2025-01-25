// Package scanner provides functionality for scanning Go source code.
package scanner

import (
	"context"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"

	"github.com/kazi-org/kazi/internal/contextstore/types"
	lstypes "github.com/kazi-org/kazi/internal/ls/types"
	"github.com/pkg/errors"
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
	// LSPClient provides language server protocol functionality
	LSPClient interface {
		GetWorkspaceSymbols(query string) ([]lstypes.WorkspaceSymbol, error)
		GetSymbolDocumentation(filePath, symbolName string) (string, error)
		GetReferences(filePath, symbolName string) ([]*lstypes.Location, error)
		GetSymbolDefinition(filePath, symbolName string) (*lstypes.SymbolDefinition, error)
		GetFileContent(filePath string) (string, error)
	}
}

// GoWorkspaceScanner implements Scanner for Go workspaces.
type GoWorkspaceScanner struct {
	config Config
	fset   *token.FileSet
}

// NewGoWorkspaceScanner creates a new scanner for Go workspaces.
func NewGoWorkspaceScanner(config Config) Scanner {
	return &GoWorkspaceScanner{
		config: config,
		fset:   token.NewFileSet(),
	}
}

// Scan implements Scanner.Scan.
func (s *GoWorkspaceScanner) Scan(ctx context.Context) (*types.CodeContext, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
	}

	codeCtx := types.NewCodeContext()

	// Get all Go files in the workspace
	err := filepath.Walk(s.config.Workspace, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && strings.HasSuffix(path, ".go") {
			relPath, err := filepath.Rel(s.config.Workspace, path)
			if err != nil {
				return errors.Wrap(err, "get relative path")
			}

			// Parse file
			f, err := parser.ParseFile(s.fset, path, nil, parser.ParseComments)
			if err != nil {
				return errors.Wrap(err, "parse file")
			}

			fileCtx := &types.FileContext{
				FilePath: relPath,
				Symbols:  make(map[string]*types.SymbolContext),
			}
			codeCtx.Files[relPath] = fileCtx

			// Process imports
			for _, imp := range f.Imports {
				path := strings.Trim(imp.Path.Value, `"`)
				if imp.Name != nil {
					path = fmt.Sprintf("%s %s", imp.Name.Name, path)
				}
			}

			// Process declarations
			for _, decl := range f.Decls {
				switch d := decl.(type) {
				case *ast.FuncDecl:
					pos := s.fset.Position(d.Pos())
					end := s.fset.Position(d.End())

					// Format function signature
					var signature string
					if d.Type.Params != nil && len(d.Type.Params.List) > 0 {
						params := make([]string, 0, len(d.Type.Params.List))
						for _, p := range d.Type.Params.List {
							paramType := fmt.Sprintf("%v", p.Type)
							if len(p.Names) > 0 {
								names := make([]string, len(p.Names))
								for i, name := range p.Names {
									names[i] = name.Name
								}
								paramType = fmt.Sprintf("%s %v", strings.Join(names, ", "), p.Type)
							}
							params = append(params, paramType)
						}
						signature = fmt.Sprintf("func %s(%s)", d.Name.Name, strings.Join(params, ", "))
					} else {
						signature = fmt.Sprintf("func %s()", d.Name.Name)
					}

					sym := &types.SymbolContext{
						Name:      d.Name.Name,
						Kind:      string(types.KindFunction),
						DocString: d.Doc.Text(),
						Signature: signature,
						Location: &lstypes.Location{
							URI: relPath,
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
						},
					}
					fileCtx.Symbols[d.Name.Name] = sym

				case *ast.GenDecl:
					for _, spec := range d.Specs {
						switch ts := spec.(type) {
						case *ast.TypeSpec:
							pos := s.fset.Position(ts.Pos())
							end := s.fset.Position(ts.End())

							sym := &types.SymbolContext{
								Name:      ts.Name.Name,
								Kind:      string(types.KindType),
								DocString: d.Doc.Text(),
								Location: &lstypes.Location{
									URI: relPath,
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
								},
							}
							fileCtx.Symbols[ts.Name.Name] = sym

						case *ast.ValueSpec:
							for _, name := range ts.Names {
								pos := s.fset.Position(name.Pos())
								end := s.fset.Position(name.End())

								kind := string(types.KindVariable)
								if d.Tok == token.CONST {
									kind = string(types.KindConstant)
								}

								sym := &types.SymbolContext{
									Name:      name.Name,
									Kind:      kind,
									DocString: d.Doc.Text(),
									Location: &lstypes.Location{
										URI: relPath,
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
									},
								}
								fileCtx.Symbols[name.Name] = sym
							}
						}
					}
				}
			}
		}
		return nil
	})

	if err != nil {
		return nil, errors.Wrap(err, "walk workspace")
	}

	return codeCtx, nil
}

func (s *GoWorkspaceScanner) scanFile(filePath string) (*types.FileContext, error) {
	// Parse the file
	f, err := parser.ParseFile(s.fset, filePath, nil, parser.ParseComments)
	if err != nil {
		return nil, fmt.Errorf("parse file: %w", err)
	}

	fileCtx := &types.FileContext{
		FilePath: filePath,
		Symbols:  make(map[string]*types.SymbolContext),
	}

	// Process declarations
	for _, decl := range f.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			pos := s.fset.Position(d.Pos())
			end := s.fset.Position(d.End())

			sym := &types.SymbolContext{
				Name:      d.Name.Name,
				Kind:      string(types.KindFunction),
				DocString: d.Doc.Text(),
				Location: &lstypes.Location{
					URI: filePath,
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
				},
			}
			fileCtx.Symbols[d.Name.Name] = sym
		}
	}

	return fileCtx, nil
}
