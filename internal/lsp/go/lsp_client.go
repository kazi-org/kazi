package lsp

import (
	"context"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/tools/go/packages"
)

// LSPClient is the interface your code references
type LSPClient interface {
	GetWorkspaceSymbols(query string) ([]WorkspaceSymbol, error)
	GetSymbolDocumentation(uri string, symbolName string) (string, error)
	GetReferences(symbol string) ([]string, error)
	GetSymbolDefinition(filePath, symbolName string) (*SymbolDefinition, error)
	GetFileContent(filePath string) (string, error)
	GetSymbolLocation(filePath, symbolName string) (Location, error)
	CheckCode(code string) (bool, string)
	Close() error
}

// GoClient implements LSPClient using the Go packages API
type GoClient struct {
	workspace string
	fset      *token.FileSet
	pkgs      []*packages.Package
}

// WorkspaceSymbol represents a symbol in the workspace
type WorkspaceSymbol struct {
	Name     string   `json:"name"`
	Kind     string   `json:"kind"`
	Location Location `json:"location"`
}

// Location represents a location in a file
type Location struct {
	URI   string `json:"uri"`
	Range Range  `json:"range"`
}

// Range represents a range in a file
type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

// Position represents a position in a file
type Position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

// SymbolDefinition represents a symbol definition
type SymbolDefinition struct {
	Name       string
	Kind       string
	Location   Location
	DocString  string
	Signature  string
	References []string
}

// NewGoClient is a variable that holds the function to create a new LSP client
var NewGoClient = func(ctx context.Context, workspace string) (LSPClient, error) {
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

// GetWorkspaceSymbols returns all symbols in the workspace that match the query
func (c *GoClient) GetWorkspaceSymbols(query string) ([]WorkspaceSymbol, error) {
	var symbols []WorkspaceSymbol
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
						symbols = append(symbols, WorkspaceSymbol{
							Name: node.Name.Name,
							Kind: "function",
							Location: Location{
								URI: filename,
								Range: Range{
									Start: Position{
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
						symbols = append(symbols, WorkspaceSymbol{
							Name: node.Name.Name,
							Kind: "type",
							Location: Location{
								URI: filename,
								Range: Range{
									Start: Position{
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
							kind := "variable"
							if inConstDecl {
								kind = "constant"
							}
							symbols = append(symbols, WorkspaceSymbol{
								Name: name.Name,
								Kind: kind,
								Location: Location{
									URI: filename,
									Range: Range{
										Start: Position{
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

// GetSymbolDocumentation returns the documentation for the given symbol
func (c *GoClient) GetSymbolDocumentation(file, symbol string) (string, error) {
	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			if filepath.Base(pkg.Fset.Position(f.Pos()).Filename) != file {
				continue
			}
			var doc string
			ast.Inspect(f, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.FuncDecl:
					if node.Name.Name == symbol && node.Doc != nil {
						doc = node.Doc.Text()
					}
				case *ast.TypeSpec:
					if node.Name.Name == symbol && node.Doc != nil {
						doc = node.Doc.Text()
					}
				case *ast.ValueSpec:
					for _, name := range node.Names {
						if name.Name == symbol && node.Doc != nil {
							doc = node.Doc.Text()
						}
					}
				}
				return true
			})
			if doc != "" {
				return strings.TrimSpace(doc), nil
			}
		}
	}
	return "", fmt.Errorf("symbol %q not found", symbol)
}

// GetReferences returns all references to the given symbol
func (c *GoClient) GetReferences(symbol string) ([]string, error) {
	var refs []string
	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			filename := pkg.Fset.Position(f.Pos()).Filename
			ast.Inspect(f, func(n ast.Node) bool {
				if id, ok := n.(*ast.Ident); ok && id.Name == symbol {
					refs = append(refs, filename)
				}
				return true
			})
		}
	}
	return refs, nil
}

// GetSymbolDefinition returns the definition of the given symbol
func (c *GoClient) GetSymbolDefinition(file, symbol string) (*SymbolDefinition, error) {
	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			if filepath.Base(pkg.Fset.Position(f.Pos()).Filename) != file {
				continue
			}
			var def *SymbolDefinition
			ast.Inspect(f, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.FuncDecl:
					if node.Name.Name == symbol {
						def = &SymbolDefinition{
							Name:      node.Name.Name,
							Kind:      "function",
							DocString: strings.TrimSpace(node.Doc.Text()),
						}
					}
				case *ast.TypeSpec:
					if node.Name.Name == symbol {
						def = &SymbolDefinition{
							Name:      node.Name.Name,
							Kind:      "type",
							DocString: strings.TrimSpace(node.Doc.Text()),
						}
					}
				case *ast.ValueSpec:
					for _, name := range node.Names {
						if name.Name == symbol {
							kind := "variable"
							if node.Type == nil {
								kind = "constant"
							}
							def = &SymbolDefinition{
								Name:      name.Name,
								Kind:      kind,
								DocString: strings.TrimSpace(node.Doc.Text()),
							}
						}
					}
				}
				return def == nil // continue until we find the definition
			})
			if def != nil {
				return def, nil
			}
		}
	}
	return nil, fmt.Errorf("symbol %q not found", symbol)
}

// GetFileContent returns the content of the given file
func (c *GoClient) GetFileContent(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}
	return string(content), nil
}

// GetSymbolLocation returns the location of the given symbol
func (c *GoClient) GetSymbolLocation(file, symbol string) (Location, error) {
	for _, pkg := range c.pkgs {
		for _, f := range pkg.Syntax {
			filename := pkg.Fset.Position(f.Pos()).Filename
			if filepath.Base(filename) != file {
				continue
			}
			var loc Location
			ast.Inspect(f, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.FuncDecl:
					if node.Name.Name == symbol {
						pos := pkg.Fset.Position(node.Pos())
						loc = Location{URI: pos.Filename}
					}
				case *ast.TypeSpec:
					if node.Name.Name == symbol {
						pos := pkg.Fset.Position(node.Pos())
						loc = Location{URI: pos.Filename}
					}
				case *ast.ValueSpec:
					for _, name := range node.Names {
						if name.Name == symbol {
							pos := pkg.Fset.Position(name.Pos())
							loc = Location{URI: pos.Filename}
						}
					}
				}
				return loc.URI == "" // continue until we find the location
			})
			if loc.URI != "" {
				return loc, nil
			}
		}
	}
	return Location{}, fmt.Errorf("symbol %q not found", symbol)
}

// CheckCode checks if the given code is valid
func (c *GoClient) CheckCode(code string) (bool, string) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "check.go", code, parser.AllErrors)
	if err != nil {
		return false, err.Error()
	}

	conf := types.Config{
		Error: func(err error) {},
		Importer: &importer{
			pkgs: c.pkgs,
		},
	}

	_, err = conf.Check("check", fset, []*ast.File{f}, nil)
	if err != nil {
		return false, err.Error()
	}

	return true, ""
}

// Close cleans up any resources used by the client
func (c *GoClient) Close() error {
	return nil
}

// importer implements types.Importer
type importer struct {
	pkgs []*packages.Package
}

func (i *importer) Import(path string) (*types.Package, error) {
	for _, pkg := range i.pkgs {
		if pkg.PkgPath == path {
			return pkg.Types, nil
		}
	}
	return nil, fmt.Errorf("package %q not found", path)
}
