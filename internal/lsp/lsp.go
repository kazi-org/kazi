// Package lsp defines a minimal interface to a Language Server Protocol client 
// or any code-analysis service (like go/ast, go/printer, etc.).

package lsp

type Issue struct {
	Severity string
	Message  string
	Line     int
	Column   int
}

type Client interface {
	// FormatCode returns a properly formatted version of the file content.
	FormatCode(filePath string) (string, error)

	// AnalyzeFile returns a list of issues or warnings in the file.
	AnalyzeFile(filePath string) ([]Issue, error)
}
