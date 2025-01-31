// internal/lsp/lsp.go

// Package lsp defines an interface for interacting with Language Server Protocol
// or any code-analysis service, enabling advanced scanning, chunking, or formatting
// for multiple languages.

package lsp

// Issue represents a single code warning/error identified during file analysis.
type Issue struct {
	Severity string // e.g. "warning", "error"
	Message  string // description of the problem
	Line     int    // line number (0-based or 1-based, up to you)
	Column   int    // column number in the line
}

// Client is a generic interface for code analysis and formatting across different languages.
//
// For each language, you create a specialized client that implements these methods.
// Example: GoLSPClient, PythonLSPClient, TypeScriptLSPClient, etc.
type Client interface {
	// FormatCode returns a formatted version of the file content.
	// Typically uses a built-in formatter or AST re-printer for the language.
	FormatCode(filePath string) (string, error)

	// AnalyzeFile returns a list of Issues found in the file. e.g., parse errors,
	// lint-like warnings, or code structure mismatches.
	AnalyzeFile(filePath string) ([]Issue, error)
}
