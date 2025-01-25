package contextstore

import (
	"fmt"
	"go/ast"
	"go/printer"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	lsp "github.com/kazi-org/kazi/internal/lsp/go"
)

// KaziContextStore is the main container that builds/refreshes the CodeContext
type KaziContextStore struct {
	mu           sync.RWMutex
	codeCtx      *CodeContext
	workspace    string
	lastScan     int64
	scanInterval int64
	lspClient    lsp.LSPClient
}

// NewKaziContextStore creates a new store with default scan interval
func NewKaziContextStore(workspace string, lspClient lsp.LSPClient) *KaziContextStore {
	return &KaziContextStore{
		codeCtx: &CodeContext{
			Files: make(map[string]*FileContext),
		},
		workspace:    workspace,
		scanInterval: 30,
		lspClient:    lspClient,
	}
}

// BuildOrRefresh scans the workspace, ignoring .git.
// Uses LSP client to extract symbols, docstrings, and other metadata
func (cs *KaziContextStore) BuildOrRefresh() error {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	now := time.Now().Unix()
	if now-cs.lastScan < cs.scanInterval {
		return nil // skip
	}
	codeCtx := &CodeContext{Files: make(map[string]*FileContext)}

	err := filepath.Walk(cs.workspace, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		// Skip .git directory
		if info.Name() == ".git" {
			return filepath.SkipDir
		}

		// Only process Go files
		if !info.IsDir() && strings.HasSuffix(path, ".go") {
			relPath, err := filepath.Rel(cs.workspace, path)
			if err != nil {
				return fmt.Errorf("get relative path: %w", err)
			}

			// Check if file is valid Go code and get its content
			content, err := cs.lspClient.GetFileContent(relPath)
			if err != nil {
				return fmt.Errorf("read file %s: %w", relPath, err)
			}
			if ok, errMsg := cs.lspClient.CheckCode(content); !ok {
				return fmt.Errorf("parse Go file %s: %s", relPath, errMsg)
			}

			// Extract package name from file content
			pkgName := "main" // default
			if lines := strings.Split(content, "\n"); len(lines) > 0 {
				if pkgLine := strings.TrimSpace(lines[0]); strings.HasPrefix(pkgLine, "package ") {
					pkgName = strings.TrimPrefix(pkgLine, "package ")
				}
			}

			// Get symbols in file
			symbols, err := cs.lspClient.GetWorkspaceSymbols("")
			if err != nil {
				return fmt.Errorf("get symbols from %s: %w", relPath, err)
			}

			fileCtx := &FileContext{
				FilePath: relPath,
				Symbols:  make(map[string]*SymbolContext),
			}

			// Convert LSP symbols to SymbolContext
			for _, sym := range symbols {
				if filepath.Base(sym.Location.URI) != filepath.Base(path) {
					continue
				}

				doc, err := cs.lspClient.GetSymbolDocumentation(filepath.Base(path), sym.Name)
				if err != nil {
					// Skip if we can't get documentation
					continue
				}

				def, err := cs.lspClient.GetSymbolDefinition(filepath.Base(path), sym.Name)
				if err != nil {
					// Skip if we can't get definition
					continue
				}

				refs, err := cs.lspClient.GetReferences(sym.Name)
				if err != nil {
					// Skip if we can't get references
					continue
				}

				fileCtx.Symbols[sym.Name] = &SymbolContext{
					Name:       sym.Name,
					Kind:       sym.Kind,
					DocString:  doc,
					StartLine:  sym.Location.Range.Start.Line + 1,
					EndLine:    sym.Location.Range.End.Line + 1,
					Signature:  def.Signature,
					Exported:   strings.Title(sym.Name) == sym.Name,
					Package:    pkgName,
					References: refs,
				}
			}

			codeCtx.Files[relPath] = fileCtx
		}

		return nil
	})

	if err != nil {
		return fmt.Errorf("walk workspace: %w", err)
	}

	cs.codeCtx = codeCtx
	cs.lastScan = now
	return nil
}

// GetCodeContext returns the current code context
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
