package types

import "encoding/json"

// Position represents a specific position in a text document
// specified as zero-based line and character offset.
type Position struct {
	Line      int `json:"line"`      // Line position in a document (zero-based)
	Character int `json:"character"` // Character offset on a line in a document (zero-based)
}

// Range represents a range in a text document expressed as (start, end) positions.
type Range struct {
	Start Position `json:"start"` // The range's start position
	End   Position `json:"end"`   // The range's end position
}

// Location represents a location inside a resource, such as a line
// inside a text file.
type Location struct {
	URI   string `json:"uri"`   // Resource identifier
	Range Range  `json:"range"` // The location's range
}

// SymbolDefinition contains information about where a symbol is defined.
type SymbolDefinition struct {
	StartLine int    // Starting line of the symbol definition
	EndLine   int    // Ending line of the symbol definition
	URI       string // Resource identifier where the symbol is defined
}

// SymbolKind denotes the kind of symbol (variable, function, etc.)
type SymbolKind int

// WorkspaceSymbol represents a program element found in the workspace.
type WorkspaceSymbol struct {
	Name     string     `json:"name"` // The name of the symbol
	Kind     SymbolKind `json:"kind"` // The kind of symbol
	Location struct {
		URI   string `json:"uri"` // Resource identifier
		Range struct {
			Start Position `json:"start"`
			End   Position `json:"end"`
		} `json:"range"`
	} `json:"location"`
}

// RequestMessage represents a JSON-RPC request message.
type RequestMessage struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int         `json:"id,omitempty"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

// ResponseMessage represents a JSON-RPC response message.
type ResponseMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int             `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *ResponseError  `json:"error,omitempty"`
}

// ResponseError represents a JSON-RPC error object.
type ResponseError struct {
	Code    int    `json:"code"`    // A number indicating the error type
	Message string `json:"message"` // A string providing a short description of the error
}
