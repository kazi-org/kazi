package types

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestPosition(t *testing.T) {
	pos := Position{Line: 10, Character: 20}

	// Test JSON marshaling
	data, err := json.Marshal(pos)
	assert.NoError(t, err)
	assert.JSONEq(t, `{"line":10,"character":20}`, string(data))

	// Test JSON unmarshaling
	var decoded Position
	err = json.Unmarshal(data, &decoded)
	assert.NoError(t, err)
	assert.Equal(t, pos, decoded)
}

func TestRange(t *testing.T) {
	r := Range{
		Start: Position{Line: 1, Character: 0},
		End:   Position{Line: 2, Character: 10},
	}

	// Test JSON marshaling
	data, err := json.Marshal(r)
	assert.NoError(t, err)
	assert.JSONEq(t, `{"start":{"line":1,"character":0},"end":{"line":2,"character":10}}`, string(data))

	// Test JSON unmarshaling
	var decoded Range
	err = json.Unmarshal(data, &decoded)
	assert.NoError(t, err)
	assert.Equal(t, r, decoded)
}

func TestLocation(t *testing.T) {
	loc := Location{
		URI: "file:///test.go",
		Range: Range{
			Start: Position{Line: 1, Character: 0},
			End:   Position{Line: 2, Character: 10},
		},
	}

	// Test JSON marshaling
	data, err := json.Marshal(loc)
	assert.NoError(t, err)
	assert.JSONEq(t, `{"uri":"file:///test.go","range":{"start":{"line":1,"character":0},"end":{"line":2,"character":10}}}`, string(data))

	// Test JSON unmarshaling
	var decoded Location
	err = json.Unmarshal(data, &decoded)
	assert.NoError(t, err)
	assert.Equal(t, loc, decoded)
}

func TestSymbolKind(t *testing.T) {
	// Test all symbol kinds
	assert.Equal(t, SymbolKind("function"), KindFunction)
	assert.Equal(t, SymbolKind("type"), KindType)
	assert.Equal(t, SymbolKind("constant"), KindConstant)
	assert.Equal(t, SymbolKind("variable"), KindVariable)

	// Test JSON marshaling
	kind := KindFunction
	data, err := json.Marshal(kind)
	assert.NoError(t, err)
	assert.JSONEq(t, `"function"`, string(data))

	// Test JSON unmarshaling
	var decoded SymbolKind
	err = json.Unmarshal(data, &decoded)
	assert.NoError(t, err)
	assert.Equal(t, kind, decoded)
}

func TestWorkspaceSymbol(t *testing.T) {
	sym := WorkspaceSymbol{
		Name: "TestFunc",
		Kind: KindFunction,
		Location: Location{
			URI: "file:///test.go",
			Range: Range{
				Start: Position{Line: 1, Character: 0},
				End:   Position{Line: 2, Character: 10},
			},
		},
	}

	// Test JSON marshaling
	data, err := json.Marshal(sym)
	assert.NoError(t, err)
	assert.JSONEq(t, `{"name":"TestFunc","kind":"function","location":{"uri":"file:///test.go","range":{"start":{"line":1,"character":0},"end":{"line":2,"character":10}}}}`, string(data))

	// Test JSON unmarshaling
	var decoded WorkspaceSymbol
	err = json.Unmarshal(data, &decoded)
	assert.NoError(t, err)
	assert.Equal(t, sym, decoded)
}

func TestSymbolDefinition(t *testing.T) {
	def := SymbolDefinition{
		Name:      "TestFunc",
		Kind:      KindFunction,
		DocString: "Test function documentation",
		Signature: "func TestFunc() error",
		Location: &Location{
			URI: "file:///test.go",
			Range: Range{
				Start: Position{Line: 1, Character: 0},
				End:   Position{Line: 2, Character: 10},
			},
		},
		References: []*Location{
			{
				URI: "file:///test.go",
				Range: Range{
					Start: Position{Line: 5, Character: 0},
					End:   Position{Line: 5, Character: 10},
				},
			},
		},
		StartLine: 1,
		EndLine:   2,
		URI:       "file:///test.go",
	}

	assert.Equal(t, "TestFunc", def.Name)
	assert.Equal(t, KindFunction, def.Kind)
	assert.Equal(t, "Test function documentation", def.DocString)
	assert.Equal(t, "func TestFunc() error", def.Signature)
	assert.NotNil(t, def.Location)
	assert.Len(t, def.References, 1)
	assert.Equal(t, 1, def.StartLine)
	assert.Equal(t, 2, def.EndLine)
	assert.Equal(t, "file:///test.go", def.URI)
}

func TestRequestMessage(t *testing.T) {
	req := RequestMessage{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "textDocument/definition",
		Params:  map[string]interface{}{"uri": "file:///test.go", "position": map[string]int{"line": 1, "character": 0}},
	}

	// Test JSON marshaling
	data, err := json.Marshal(req)
	assert.NoError(t, err)
	assert.JSONEq(t, `{"jsonrpc":"2.0","id":1,"method":"textDocument/definition","params":{"uri":"file:///test.go","position":{"line":1,"character":0}}}`, string(data))

	// Test JSON unmarshaling
	var decoded RequestMessage
	err = json.Unmarshal(data, &decoded)
	assert.NoError(t, err)
	assert.Equal(t, req.JSONRPC, decoded.JSONRPC)
	assert.Equal(t, req.ID, decoded.ID)
	assert.Equal(t, req.Method, decoded.Method)
}

func TestResponseMessage(t *testing.T) {
	resp := ResponseMessage{
		JSONRPC: "2.0",
		ID:      1,
		Result:  json.RawMessage(`{"uri":"file:///test.go"}`),
	}

	// Test JSON marshaling
	data, err := json.Marshal(resp)
	assert.NoError(t, err)
	assert.JSONEq(t, `{"jsonrpc":"2.0","id":1,"result":{"uri":"file:///test.go"}}`, string(data))

	// Test JSON unmarshaling
	var decoded ResponseMessage
	err = json.Unmarshal(data, &decoded)
	assert.NoError(t, err)
	assert.Equal(t, resp.JSONRPC, decoded.JSONRPC)
	assert.Equal(t, resp.ID, decoded.ID)
	assert.Equal(t, string(resp.Result), string(decoded.Result))

	// Test with error
	respWithError := ResponseMessage{
		JSONRPC: "2.0",
		ID:      1,
		Error: &ResponseError{
			Code:    -32600,
			Message: "Invalid Request",
		},
	}

	data, err = json.Marshal(respWithError)
	assert.NoError(t, err)
	assert.JSONEq(t, `{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid Request"}}`, string(data))

	var decodedWithError ResponseMessage
	err = json.Unmarshal(data, &decodedWithError)
	assert.NoError(t, err)
	assert.Equal(t, respWithError.Error.Code, decodedWithError.Error.Code)
	assert.Equal(t, respWithError.Error.Message, decodedWithError.Error.Message)
}

func TestResponseError(t *testing.T) {
	err := ResponseError{
		Code:    -32700,
		Message: "Parse error",
	}

	// Test JSON marshaling
	data, err2 := json.Marshal(err)
	assert.NoError(t, err2)
	assert.JSONEq(t, `{"code":-32700,"message":"Parse error"}`, string(data))

	// Test JSON unmarshaling
	var decoded ResponseError
	err2 = json.Unmarshal(data, &decoded)
	assert.NoError(t, err2)
	assert.Equal(t, err.Code, decoded.Code)
	assert.Equal(t, err.Message, decoded.Message)
}
