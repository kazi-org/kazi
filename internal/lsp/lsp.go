// internal/lsp/lsp.go
//
// Package lsp defines interfaces to interact with a Language Server Protocol (LSP) client
// or any code-analysis service. It supports code formatting and analysis to ensure
// code quality and adherence to style/security standards.
package lsp

// Issue represents a code issue or warning identified by the LSP.
type Issue struct {
	Severity string // e.g., "warning" or "error"
	Message  string // Detailed message about the issue
	Line     int    // Line number where the issue was found
	Column   int    // Column number where the issue was found
}

// Client defines an interface for interacting with an LSP or code analysis service.
type Client interface {
	// FormatCode returns a properly formatted version of the file content.
	FormatCode(filePath string) (string, error)

	// AnalyzeFile returns a list of issues or warnings found in the file.
	AnalyzeFile(filePath string) ([]Issue, error)
}
