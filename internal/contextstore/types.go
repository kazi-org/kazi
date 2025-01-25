package contextstore

// CodeContext represents the entire workspace's code context
type CodeContext struct {
	Files map[string]*FileContext // path -> FileContext
}

// FileContext represents a single file's context
type FileContext struct {
	FilePath string                    // relative path in workspace
	Imports  []string                  // import paths
	Symbols  map[string]*SymbolContext // name -> SymbolContext
}

// SymbolContext represents a single symbol (function, type, const, var)
type SymbolContext struct {
	Name       string   // symbol name
	Kind       string   // "function", "type", "value", etc.
	DocString  string   // documentation comments
	CodeLines  []string // actual code lines
	StartLine  int      // 1-based start line
	EndLine    int      // 1-based end line inclusive
	Signature  string   // function signature or type definition
	Exported   bool     // whether the symbol is exported
	Package    string   // package name
	References []string // list of files referencing this symbol
	Rank       int      // optional ranking for search results
}
