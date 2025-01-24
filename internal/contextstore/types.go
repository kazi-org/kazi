package contextstore

// CodeContext is the top-level container merging a "repo map" with doc/lines store
type CodeContext struct {
    Files map[string]*FileContext
}

// FileContext represents a single file's data (symbols, references, docstrings).
type FileContext struct {
    FilePath    string
    Imports     []string
    Symbols     map[string]*SymbolContext
    // Optional adjacency references to other files (like a mini-graph).
}

// SymbolContext merges docstrings + partial code lines for a single symbol
type SymbolContext struct {
    Name       string
    Kind       string
    DocString  string
    CodeLines  []string
    StartLine  int
    EndLine    int
    References []string // references to other files/symbols
    Rank       int
}
