// internal/lsp/golang_lsp.go

package lsp

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"os"

	"golang.org/x/tools/go/packages"
)

// GoLSPClient implements the Client interface for Go code, using standard
// libraries (ast, parser, printer, token) plus optional "golang.org/x/tools/go/packages"
// for deeper analysis. This approach can parse files, produce warnings, and
// provide a formatted version of the code.
type GoLSPClient struct {
	// WorkDir is the workspace directory, if needed. Could be used to load
	// multiple files or packages from a base path.
	WorkDir string

	// If you plan to do deeper analysis with "go/packages," you might store
	// some initial package load or config here.
}

// NewGoLSPClient constructs a new GoLSPClient referencing a workspace dir or config.
func NewGoLSPClient(workDir string) *GoLSPClient {
	return &GoLSPClient{
		WorkDir: workDir,
	}
}

// FormatCode uses "go/parser" + "go/printer" to parse and re-print the code
// with standard formatting, returning the formatted source as a string.
func (g *GoLSPClient) FormatCode(filePath string) (string, error) {
	// 1. Read file
	src, err := os.ReadFile(filePath)
	if err != nil {
		return "", fmt.Errorf("read file: %w", err)
	}

	// 2. Parse the file
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if err != nil {
		return "", fmt.Errorf("parse file %s: %w", filePath, err)
	}

	// 3. Print (format) the AST
	var buf bytes.Buffer
	cfg := printer.Config{Mode: printer.TabIndent | printer.UseSpaces, Tabwidth: 4}
	if err := cfg.Fprint(&buf, fset, f); err != nil {
		return "", fmt.Errorf("format file %s: %w", filePath, err)
	}

	return buf.String(), nil
}

// AnalyzeFile attempts to parse the file for basic syntax/lint-like issues
// and returns them as a slice of Issues. For deeper checks, we might rely
// on "golang.org/x/tools/go/packages" to do type-checking or analysis across packages.
func (g *GoLSPClient) AnalyzeFile(filePath string) ([]Issue, error) {
	var issues []Issue

	src, err := os.ReadFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("read file %s: %w", filePath, err)
	}

	// Basic parse to catch syntax errors
	fset := token.NewFileSet()
	_, parseErr := parser.ParseFile(fset, filePath, src, parser.AllErrors)
	if parseErr != nil {
		// parser.AllErrors can contain multiple errors. We might cast it to
		// a special error type to gather them. For simplicity, we treat it
		// as one Issue here, but you can expand if needed.
		issues = append(issues, Issue{
			Severity: "error",
			Message:  parseErr.Error(),
			Line:     0, // We don't have a direct line number from parse errors unless we parse them out
			Column:   0,
		})
	}

	// (Optional) deeper analysis with go/packages
	// If we want to do type checks or cross-file references:
	/*
		cfg := &packages.Config{
			Mode:  packages.NeedName | packages.NeedSyntax | packages.NeedTypes | packages.NeedDeps,
			Dir:   g.WorkDir,
			Tests: false,
		}
		pkgs, err := packages.Load(cfg, filePath)
		if err == nil {
			for _, p := range pkgs {
				for _, e := range p.Errors {
					issues = append(issues, Issue{
						Severity: "error",
						Message:  e.Error(),
					})
				}
			}
		} else {
			// If there's a problem with packages.Load, it might be
			// okay to treat it as a mild error or just skip deeper checks.
		}
	*/

	return issues, nil
}
