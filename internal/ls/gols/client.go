// Package gols provides a Go Language Server Protocol client implementation.
package gols

import (
	"context"
	"fmt"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"strings"
	"sync"

	"github.com/kazi-org/kazi/internal/ls/types"
	"golang.org/x/tools/go/packages"
)

// GoClient implements LSPClient using the Go packages API.
// It provides thread-safe access to workspace symbols and code analysis.
type GoClient struct {
	mu        sync.RWMutex
	workspace string
	fset      *token.FileSet
	pkgs      []*packages.Package
}

// NewGoClient creates a new LSP client for the given workspace.
// It initializes the client with package information from the workspace.
func NewGoClient(ctx context.Context, workspace string) (LSPClient, error) {
	client := &GoClient{
		workspace: workspace,
		fset:      token.NewFileSet(),
	}

	cfg := &packages.Config{
		Mode: packages.NeedName | packages.NeedFiles | packages.NeedSyntax |
			packages.NeedTypes | packages.NeedTypesInfo | packages.NeedDeps,
		Dir: workspace,
		Env: os.Environ(),
	}

	pkgs, err := packages.Load(cfg, "./...")
	if err != nil {
		return nil, fmt.Errorf("load packages: %w", err)
	}

	client.pkgs = pkgs
	return client, nil
}

// GetWorkspaceSymbols returns all symbols in the workspace matching the query.
func (c *GoClient) GetWorkspaceSymbols(query string) ([]types.WorkspaceSymbol, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	var symbols []types.WorkspaceSymbol
	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			filename := pkg.Fset.Position(f.Pos()).Filename
			var inConstDecl bool
			ast.Inspect(f, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.GenDecl:
					inConstDecl = node.Tok == token.CONST
					return true
				case *ast.FuncDecl:
					if strings.Contains(node.Name.Name, query) || node.Name.Name == "main" {
						pos := pkg.Fset.Position(node.Pos())
						symbols = append(symbols, types.WorkspaceSymbol{
							Name: node.Name.Name,
							Kind: types.KindFunction,
							Location: types.Location{
								URI: filename,
								Range: types.Range{
									Start: types.Position{
										Line:      pos.Line - 1,
										Character: pos.Column - 1,
									},
								},
							},
						})
					}
				case *ast.TypeSpec:
					if strings.Contains(node.Name.Name, query) {
						pos := pkg.Fset.Position(node.Pos())
						symbols = append(symbols, types.WorkspaceSymbol{
							Name: node.Name.Name,
							Kind: types.KindType,
							Location: types.Location{
								URI: filename,
								Range: types.Range{
									Start: types.Position{
										Line:      pos.Line - 1,
										Character: pos.Column - 1,
									},
								},
							},
						})
					}
				case *ast.ValueSpec:
					for _, name := range node.Names {
						if strings.Contains(name.Name, query) {
							pos := pkg.Fset.Position(name.Pos())
							kind := types.KindVariable
							if inConstDecl {
								kind = types.KindConstant
							}
							symbols = append(symbols, types.WorkspaceSymbol{
								Name: name.Name,
								Kind: kind,
								Location: types.Location{
									URI: filename,
									Range: types.Range{
										Start: types.Position{
											Line:      pos.Line - 1,
											Character: pos.Column - 1,
										},
									},
								},
							})
						}
					}
				}
				return true
			})
		}
	}
	return symbols, nil
}

// GetSymbolDocumentation returns the documentation for a symbol.
func (c *GoClient) GetSymbolDocumentation(uri string, symbolName string) (string, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			filename := pkg.Fset.Position(f.Pos()).Filename
			if filename != uri {
				continue
			}

			var doc string
			ast.Inspect(f, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.FuncDecl:
					if node.Name.Name == symbolName && node.Doc != nil {
						doc = node.Doc.Text()
						return false
					}
				case *ast.TypeSpec:
					if node.Name.Name == symbolName && node.Doc != nil {
						doc = node.Doc.Text()
						return false
					}
				case *ast.ValueSpec:
					for _, name := range node.Names {
						if name.Name == symbolName && node.Doc != nil {
							doc = node.Doc.Text()
							return false
						}
					}
				}
				return true
			})

			if doc != "" {
				return doc, nil
			}
		}
	}

	return "", fmt.Errorf("symbol %q not found in %s", symbolName, uri)
}

// GetReferences returns all references to the given symbol.
func (c *GoClient) GetReferences(filePath, symbolName string) ([]*types.Location, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	var refs []*types.Location
	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			filename := pkg.Fset.Position(f.Pos()).Filename
			ast.Inspect(f, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.Ident:
					if node.Name == symbolName {
						pos := pkg.Fset.Position(node.Pos())
						end := pkg.Fset.Position(node.End())
						refs = append(refs, &types.Location{
							URI: filename,
							Range: types.Range{
								Start: types.Position{
									Line:      pos.Line - 1,
									Character: pos.Column - 1,
								},
								End: types.Position{
									Line:      end.Line - 1,
									Character: end.Column - 1,
								},
							},
						})
					}
				}
				return true
			})
		}
	}

	if len(refs) == 0 {
		return nil, fmt.Errorf("no references found for symbol %q in %s", symbolName, filePath)
	}

	return refs, nil
}

// GetSymbolDefinition returns the definition of a symbol.
func (c *GoClient) GetSymbolDefinition(filePath, symbolName string) (*types.SymbolDefinition, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			filename := pkg.Fset.Position(f.Pos()).Filename
			if filename != filePath {
				continue
			}

			var def *types.SymbolDefinition
			ast.Inspect(f, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.FuncDecl:
					if node.Name.Name == symbolName {
						pos := pkg.Fset.Position(node.Pos())
						end := pkg.Fset.Position(node.End())
						def = &types.SymbolDefinition{
							Name: node.Name.Name,
							Kind: types.KindFunction,
							Location: &types.Location{
								URI: filename,
								Range: types.Range{
									Start: types.Position{
										Line:      pos.Line - 1,
										Character: pos.Column - 1,
									},
									End: types.Position{
										Line:      end.Line - 1,
										Character: end.Column - 1,
									},
								},
							},
							DocString: node.Doc.Text(),
							Signature: c.formatSignature(node.Type),
						}
						return false
					}
				case *ast.TypeSpec:
					if node.Name.Name == symbolName {
						pos := pkg.Fset.Position(node.Pos())
						end := pkg.Fset.Position(node.End())
						def = &types.SymbolDefinition{
							Name: node.Name.Name,
							Kind: types.KindType,
							Location: &types.Location{
								URI: filename,
								Range: types.Range{
									Start: types.Position{
										Line:      pos.Line - 1,
										Character: pos.Column - 1,
									},
									End: types.Position{
										Line:      end.Line - 1,
										Character: end.Column - 1,
									},
								},
							},
							DocString: node.Doc.Text(),
							Signature: c.formatType(node.Type),
						}
						return false
					}
				case *ast.ValueSpec:
					for _, name := range node.Names {
						if name.Name == symbolName {
							pos := pkg.Fset.Position(name.Pos())
							end := pkg.Fset.Position(name.End())
							kind := types.KindVariable
							if node.Type != nil {
								kind = types.KindConstant
							}
							def = &types.SymbolDefinition{
								Name: name.Name,
								Kind: kind,
								Location: &types.Location{
									URI: filename,
									Range: types.Range{
										Start: types.Position{
											Line:      pos.Line - 1,
											Character: pos.Column - 1,
										},
										End: types.Position{
											Line:      end.Line - 1,
											Character: end.Column - 1,
										},
									},
								},
								DocString: node.Doc.Text(),
								Signature: c.formatType(node.Type),
							}
							return false
						}
					}
				}
				return true
			})

			if def != nil {
				return def, nil
			}
		}
	}

	return nil, fmt.Errorf("symbol %q not found in %s", symbolName, filePath)
}

// GetFileContent returns the content of a file.
func (c *GoClient) GetFileContent(filePath string) (string, error) {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}
	return string(content), nil
}

// Close closes the client connection.
func (c *GoClient) Close() error {
	return nil
}

// formatSignature formats a function signature.
func (c *GoClient) formatSignature(ft *ast.FuncType) string {
	var params, results []string

	// Format parameters
	if ft.Params != nil {
		for _, p := range ft.Params.List {
			param := c.formatType(p.Type)
			if len(p.Names) > 0 {
				names := make([]string, len(p.Names))
				for i, name := range p.Names {
					names[i] = name.Name
				}
				param = fmt.Sprintf("%s %s", strings.Join(names, ", "), param)
			}
			params = append(params, param)
		}
	}

	// Format results
	if ft.Results != nil {
		for _, r := range ft.Results.List {
			result := c.formatType(r.Type)
			if len(r.Names) > 0 {
				names := make([]string, len(r.Names))
				for i, name := range r.Names {
					names[i] = name.Name
				}
				result = fmt.Sprintf("%s %s", strings.Join(names, ", "), result)
			}
			results = append(results, result)
		}
	}

	// Build signature string
	sig := fmt.Sprintf("func(%s)", strings.Join(params, ", "))
	if len(results) > 0 {
		if len(results) == 1 && !strings.Contains(results[0], " ") {
			sig += " " + results[0]
		} else {
			sig += fmt.Sprintf(" (%s)", strings.Join(results, ", "))
		}
	}

	return sig
}

// formatType formats a type expression.
func (c *GoClient) formatType(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.SelectorExpr:
		return fmt.Sprintf("%s.%s", c.formatType(t.X), t.Sel.Name)
	case *ast.StarExpr:
		return "*" + c.formatType(t.X)
	case *ast.ArrayType:
		if t.Len == nil {
			return "[]" + c.formatType(t.Elt)
		}
		return fmt.Sprintf("[%s]%s", c.formatType(t.Len), c.formatType(t.Elt))
	case *ast.MapType:
		return fmt.Sprintf("map[%s]%s", c.formatType(t.Key), c.formatType(t.Value))
	case *ast.InterfaceType:
		return "interface{}"
	case *ast.StructType:
		return "struct{}"
	case *ast.FuncType:
		return c.formatSignature(t)
	case *ast.ChanType:
		switch t.Dir {
		case ast.SEND:
			return fmt.Sprintf("chan<- %s", c.formatType(t.Value))
		case ast.RECV:
			return fmt.Sprintf("<-chan %s", c.formatType(t.Value))
		default:
			return fmt.Sprintf("chan %s", c.formatType(t.Value))
		}
	case *ast.Ellipsis:
		return "..." + c.formatType(t.Elt)
	default:
		return fmt.Sprintf("%T", expr)
	}
}

// GetSymbolLocation returns the location of a symbol in a file.
func (c *GoClient) GetSymbolLocation(filePath, symbolName string) (*types.Location, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			filename := pkg.Fset.Position(f.Pos()).Filename
			if filename != filePath {
				continue
			}

			var loc types.Location
			ast.Inspect(f, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.FuncDecl:
					if node.Name.Name == symbolName {
						pos := pkg.Fset.Position(node.Pos())
						end := pkg.Fset.Position(node.End())
						loc = types.Location{
							URI: filename,
							Range: types.Range{
								Start: types.Position{
									Line:      pos.Line - 1,
									Character: pos.Column - 1,
								},
								End: types.Position{
									Line:      end.Line - 1,
									Character: end.Column - 1,
								},
							},
						}
						return false
					}
				case *ast.TypeSpec:
					if node.Name.Name == symbolName {
						pos := pkg.Fset.Position(node.Pos())
						end := pkg.Fset.Position(node.End())
						loc = types.Location{
							URI: filename,
							Range: types.Range{
								Start: types.Position{
									Line:      pos.Line - 1,
									Character: pos.Column - 1,
								},
								End: types.Position{
									Line:      end.Line - 1,
									Character: end.Column - 1,
								},
							},
						}
						return false
					}
				case *ast.ValueSpec:
					for _, name := range node.Names {
						if name.Name == symbolName {
							pos := pkg.Fset.Position(name.Pos())
							end := pkg.Fset.Position(name.End())
							loc = types.Location{
								URI: filename,
								Range: types.Range{
									Start: types.Position{
										Line:      pos.Line - 1,
										Character: pos.Column - 1,
									},
									End: types.Position{
										Line:      end.Line - 1,
										Character: end.Column - 1,
									},
								},
							}
							return false
						}
					}
				}
				return true
			})

			if loc.URI != "" {
				return &loc, nil
			}
		}
	}

	return nil, fmt.Errorf("symbol %q not found in %s", symbolName, filePath)
}

// CheckCode validates the given Go code and returns whether it's valid.
func (c *GoClient) CheckCode(code string) (bool, error) {
	fset := token.NewFileSet()
	_, err := parser.ParseFile(fset, "check.go", code, parser.AllErrors)
	if err != nil {
		return false, fmt.Errorf("invalid Go code: %v", err)
	}
	return true, nil
}

// FormatFile formats a Go file using gofmt.
func (c *GoClient) FormatFile(filePath string) (string, error) {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}

	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filePath, content, parser.ParseComments)
	if err != nil {
		return "", fmt.Errorf("parse file: %w", err)
	}

	var buf strings.Builder
	if err := printer.Fprint(&buf, fset, f); err != nil {
		return "", fmt.Errorf("format file: %w", err)
	}

	return buf.String(), nil
}
