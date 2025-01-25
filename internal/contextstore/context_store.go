package contextstore

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
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
// Parses Go files to extract symbols, docstrings, and other metadata
func (cs *KaziContextStore) BuildOrRefresh() error {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	now := time.Now().Unix()
	if now-cs.lastScan < cs.scanInterval {
		return nil // skip
	}
	codeCtx := &CodeContext{Files: make(map[string]*FileContext)}

	// Create a new token.FileSet to track positions in parsed files
	fset := token.NewFileSet()

	err := filepath.Walk(cs.workspace, func(path string, info os.FileInfo, werr error) error {
		if werr != nil {
			return werr
		}
		if info.IsDir() {
			if info.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		rel, _ := filepath.Rel(cs.workspace, path)

		// skip non-go or .gitignore
		if !strings.HasSuffix(rel, ".go") || strings.HasSuffix(rel, ".gitignore") {
			return nil
		}

		// Parse the Go file
		astFile, err := parser.ParseFile(fset, path, nil, parser.ParseComments)
		if err != nil {
			return fmt.Errorf("parse Go file %s: %w", rel, err)
		}

		fc := &FileContext{
			FilePath: rel,
			Imports:  make([]string, 0, len(astFile.Imports)),
			Symbols:  make(map[string]*SymbolContext),
		}

		// Extract imports
		for _, imp := range astFile.Imports {
			if imp.Path != nil {
				// Remove quotes from import path
				importPath := strings.Trim(imp.Path.Value, "\"")
				fc.Imports = append(fc.Imports, importPath)
			}
		}

		// Extract symbols (functions, types, etc.)
		ast.Inspect(astFile, func(n ast.Node) bool {
			switch node := n.(type) {
			case *ast.GenDecl:
				// Handle const and var declarations
				if node.Tok == token.CONST || node.Tok == token.VAR {
					for _, spec := range node.Specs {
						if valueSpec, ok := spec.(*ast.ValueSpec); ok {
							for _, name := range valueSpec.Names {
								sc := &SymbolContext{
									Name:      name.Name,
									Kind:      strings.ToLower(node.Tok.String()), // "const" or "var"
									StartLine: fset.Position(valueSpec.Pos()).Line,
									EndLine:   fset.Position(valueSpec.End()).Line,
									Package:   astFile.Name.Name,
									Exported:  name.IsExported(),
								}
								if valueSpec.Doc != nil {
									sc.DocString = valueSpec.Doc.Text()
								} else if node.Doc != nil {
									sc.DocString = node.Doc.Text()
								}
								// Get value signature
								if valueSpec.Type != nil {
									sc.Signature = fmt.Sprintf("%s %s", name.Name, formatNode(valueSpec.Type))
								}
								// Get value definition as code lines
								start := fset.Position(valueSpec.Pos()).Line
								end := fset.Position(valueSpec.End()).Line
								data, err := os.ReadFile(path)
								if err == nil {
									lines := strings.Split(string(data), "\n")
									if start > 0 && end <= len(lines) {
										sc.CodeLines = lines[start-1 : end]
									}
								}
								fc.Symbols[sc.Name] = sc
							}
						}
					}
				} else if node.Tok == token.TYPE {
					// Handle type declarations
					for _, spec := range node.Specs {
						if typeSpec, ok := spec.(*ast.TypeSpec); ok {
							sc := &SymbolContext{
								Name:       typeSpec.Name.Name,
								Kind:       "type",
								StartLine:  fset.Position(typeSpec.Pos()).Line,
								EndLine:    fset.Position(typeSpec.End()).Line,
								Package:    astFile.Name.Name,
								Exported:   typeSpec.Name.IsExported(),
								References: []string{rel},
							}
							// Get doc string from type spec or parent GenDecl
							if typeSpec.Doc != nil {
								sc.DocString = typeSpec.Doc.Text()
							} else if node.Doc != nil {
								sc.DocString = node.Doc.Text()
							}
							fc.Symbols[typeSpec.Name.Name] = sc
						}
					}
				}

			case *ast.FuncDecl:
				// Function declaration
				sc := &SymbolContext{
					Name:       node.Name.Name,
					Kind:       "function",
					DocString:  node.Doc.Text(),
					StartLine:  fset.Position(node.Pos()).Line,
					EndLine:    fset.Position(node.End()).Line,
					Package:    astFile.Name.Name,
					Exported:   node.Name.IsExported(),
					Signature:  getFuncSignature(node),
					References: []string{rel},
				}
				fc.Symbols[node.Name.Name] = sc
			}
			return true
		})

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

// GetCodeContext returns the read-only CodeContext
func (cs *KaziContextStore) GetCodeContext() *CodeContext {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.codeCtx
}

// formatFuncType formats a function type into a string
func formatFuncType(ft *ast.FuncType) string {
	var params, results []string

	// Format parameters
	if ft.Params != nil {
		for _, p := range ft.Params.List {
			param := formatNode(p.Type)
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
			result := formatNode(r.Type)
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

	// Combine into signature
	signature := fmt.Sprintf("(%s)", strings.Join(params, ", "))
	if len(results) > 0 {
		if len(results) == 1 && !strings.Contains(results[0], " ") {
			signature += " " + results[0]
		} else {
			signature += fmt.Sprintf(" (%s)", strings.Join(results, ", "))
		}
	}
	return signature
}

// formatNode formats an AST node into a string
func formatNode(node ast.Node) string {
	switch n := node.(type) {
	case *ast.Ident:
		return n.Name
	case *ast.StarExpr:
		return "*" + formatNode(n.X)
	case *ast.ArrayType:
		if n.Len == nil {
			return "[]" + formatNode(n.Elt)
		}
		return fmt.Sprintf("[%s]%s", formatNode(n.Len), formatNode(n.Elt))
	case *ast.MapType:
		return fmt.Sprintf("map[%s]%s", formatNode(n.Key), formatNode(n.Value))
	case *ast.InterfaceType:
		return "interface{}"
	case *ast.StructType:
		return "struct{}"
	case *ast.BasicLit:
		return n.Value
	case *ast.SelectorExpr:
		return fmt.Sprintf("%s.%s", formatNode(n.X), n.Sel.Name)
	default:
		return fmt.Sprintf("<%T>", node)
	}
}

// getFuncSignature returns a string representation of a function's signature
func getFuncSignature(fn *ast.FuncDecl) string {
	var buf strings.Builder
	buf.WriteString("func ")
	if fn.Recv != nil {
		buf.WriteByte('(')
		if len(fn.Recv.List) > 0 {
			if len(fn.Recv.List[0].Names) > 0 {
				buf.WriteString(fn.Recv.List[0].Names[0].Name)
				buf.WriteByte(' ')
			}
			printer.Fprint(&buf, token.NewFileSet(), fn.Recv.List[0].Type)
		}
		buf.WriteString(") ")
	}
	buf.WriteString(fn.Name.Name)
	buf.WriteByte('(')
	if fn.Type.Params != nil && len(fn.Type.Params.List) > 0 {
		for i, param := range fn.Type.Params.List {
			if i > 0 {
				buf.WriteString(", ")
			}
			if len(param.Names) > 0 {
				for j, name := range param.Names {
					if j > 0 {
						buf.WriteString(", ")
					}
					buf.WriteString(name.Name)
				}
				buf.WriteByte(' ')
			}
			printer.Fprint(&buf, token.NewFileSet(), param.Type)
		}
	}
	buf.WriteByte(')')
	if fn.Type.Results != nil {
		buf.WriteByte(' ')
		if len(fn.Type.Results.List) > 1 || (len(fn.Type.Results.List) == 1 && len(fn.Type.Results.List[0].Names) > 0) {
			buf.WriteString("(")
		}
		for i, result := range fn.Type.Results.List {
			if i > 0 {
				buf.WriteString(", ")
			}
			if len(result.Names) > 0 {
				for j, name := range result.Names {
					if j > 0 {
						buf.WriteString(", ")
					}
					buf.WriteString(name.Name)
				}
				buf.WriteByte(' ')
			}
			printer.Fprint(&buf, token.NewFileSet(), result.Type)
		}
		if len(fn.Type.Results.List) > 1 || (len(fn.Type.Results.List) == 1 && len(fn.Type.Results.List[0].Names) > 0) {
			buf.WriteString(")")
		}
	}
	return buf.String()
}
