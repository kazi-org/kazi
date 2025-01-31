// Package lsp defines a minimal interface for a Language Server Protocol or
// equivalent code analysis service, enabling advanced scanning, chunking, or formatting.

package lsp

// Issue represents a single code warning/error from the LSP.
type Issue struct {
	Severity string
	Message  string
	Line     int
	Column   int
}

// Client allows basic code analysis and formatting. 
// In a real system, you might expand this to handle references, symbol queries, etc.
type Client interface {
	FormatCode(filePath string) (string, error)
	AnalyzeFile(filePath string) ([]Issue, error)
}
