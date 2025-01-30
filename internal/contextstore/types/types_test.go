package types

import (
	"testing"

	"github.com/kazi-org/kazi/internal/ls/types"
	"github.com/stretchr/testify/assert"
)

func TestNewCodeContext(t *testing.T) {
	ctx := NewCodeContext()
	assert.NotNil(t, ctx)
	assert.NotNil(t, ctx.Files)
	assert.Empty(t, ctx.Files)
}

func TestCodeContext_GetSymbol(t *testing.T) {
	ctx := NewCodeContext()

	// Create test data
	testSymbol := &SymbolContext{
		Name:      "testFunc",
		Kind:      string(KindFunction),
		DocString: "Test function documentation",
		Signature: "func testFunc() error",
		Location: &types.Location{
			URI: "test.go",
			Range: types.Range{
				Start: types.Position{Line: 1, Character: 0},
				End:   types.Position{Line: 1, Character: 10},
			},
		},
		References: []*types.Location{
			{
				URI: "test.go",
				Range: types.Range{
					Start: types.Position{Line: 5, Character: 0},
					End:   types.Position{Line: 5, Character: 10},
				},
			},
		},
	}

	// Add file context with symbol
	ctx.Files["test.go"] = &FileContext{
		FilePath: "test.go",
		Content:  "package test\n\nfunc testFunc() error { return nil }\n",
		Symbols: map[string]*SymbolContext{
			"testFunc": testSymbol,
		},
	}

	t.Run("existing symbol", func(t *testing.T) {
		sym := ctx.GetSymbol("testFunc")
		assert.NotNil(t, sym)
		assert.Equal(t, "testFunc", sym.Name)
		assert.Equal(t, string(KindFunction), sym.Kind)
		assert.Equal(t, "Test function documentation", sym.DocString)
		assert.Equal(t, "func testFunc() error", sym.Signature)
		assert.NotNil(t, sym.Location)
		assert.Equal(t, "test.go", sym.Location.URI)
		assert.Len(t, sym.References, 1)
	})

	t.Run("non-existent symbol", func(t *testing.T) {
		sym := ctx.GetSymbol("nonexistent")
		assert.Nil(t, sym)
	})
}

func TestCodeContext_GetFile(t *testing.T) {
	ctx := NewCodeContext()

	// Create test file context
	fileCtx := &FileContext{
		FilePath: "test.go",
		Content:  "package test\n",
		Symbols:  make(map[string]*SymbolContext),
	}
	ctx.Files["test.go"] = fileCtx

	t.Run("existing file", func(t *testing.T) {
		file := ctx.GetFile("test.go")
		assert.NotNil(t, file)
		assert.Equal(t, "test.go", file.FilePath)
		assert.Equal(t, "package test\n", file.Content)
		assert.NotNil(t, file.Symbols)
	})

	t.Run("non-existent file", func(t *testing.T) {
		file := ctx.GetFile("nonexistent.go")
		assert.Nil(t, file)
	})
}

func TestSymbolKinds(t *testing.T) {
	// Test all symbol kinds are defined correctly
	assert.Equal(t, SymbolKind("function"), KindFunction)
	assert.Equal(t, SymbolKind("type"), KindType)
	assert.Equal(t, SymbolKind("constant"), KindConstant)
	assert.Equal(t, SymbolKind("variable"), KindVariable)
}

func TestFileContext(t *testing.T) {
	fileCtx := &FileContext{
		FilePath: "test.go",
		Content:  "package test\n\nfunc testFunc() {}\n",
		Symbols: map[string]*SymbolContext{
			"testFunc": {
				Name:      "testFunc",
				Kind:      string(KindFunction),
				DocString: "Test function",
				Signature: "func testFunc()",
			},
		},
	}

	assert.Equal(t, "test.go", fileCtx.FilePath)
	assert.Equal(t, "package test\n\nfunc testFunc() {}\n", fileCtx.Content)
	assert.Len(t, fileCtx.Symbols, 1)
	assert.Contains(t, fileCtx.Symbols, "testFunc")
}

func TestSymbolContext(t *testing.T) {
	sym := &SymbolContext{
		Name:      "testFunc",
		Kind:      string(KindFunction),
		DocString: "Test function",
		Signature: "func testFunc()",
		Location: &types.Location{
			URI: "test.go",
			Range: types.Range{
				Start: types.Position{Line: 1, Character: 0},
				End:   types.Position{Line: 1, Character: 10},
			},
		},
		References: []*types.Location{
			{
				URI: "test.go",
				Range: types.Range{
					Start: types.Position{Line: 5, Character: 0},
					End:   types.Position{Line: 5, Character: 10},
				},
			},
		},
	}

	assert.Equal(t, "testFunc", sym.Name)
	assert.Equal(t, string(KindFunction), sym.Kind)
	assert.Equal(t, "Test function", sym.DocString)
	assert.Equal(t, "func testFunc()", sym.Signature)
	assert.NotNil(t, sym.Location)
	assert.Equal(t, "test.go", sym.Location.URI)
	assert.Len(t, sym.References, 1)
	assert.Equal(t, "test.go", sym.References[0].URI)
}
