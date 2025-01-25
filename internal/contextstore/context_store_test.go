package contextstore

import (
	"context"
	"strings"
	"testing"

	"github.com/kazi-org/kazi/internal/contextstore/types"
	gols "github.com/kazi-org/kazi/internal/ls/gols"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
)

// mockLSPClient implements lsp.LSPClient for testing
type mockLSPClient struct {
	mock.Mock
}

func (m *mockLSPClient) GetWorkspaceSymbols(query string) ([]gols.WorkspaceSymbol, error) {
	args := m.Called(query)
	return args.Get(0).([]gols.WorkspaceSymbol), args.Error(1)
}

func (m *mockLSPClient) GetSymbolDocumentation(uri string, symbolName string) (string, error) {
	args := m.Called(uri, symbolName)
	return args.String(0), args.Error(1)
}

func (m *mockLSPClient) GetReferences(symbol string) ([]string, error) {
	args := m.Called(symbol)
	return args.Get(0).([]string), args.Error(1)
}

func (m *mockLSPClient) GetSymbolDefinition(filePath, symbolName string) (*gols.SymbolDefinition, error) {
	args := m.Called(filePath, symbolName)
	return args.Get(0).(*gols.SymbolDefinition), args.Error(1)
}

func (m *mockLSPClient) GetFileContent(filePath string) (string, error) {
	args := m.Called(filePath)
	return args.String(0), args.Error(1)
}

func (m *mockLSPClient) GetSymbolLocation(filePath, symbolName string) (gols.Location, error) {
	args := m.Called(filePath, symbolName)
	return args.Get(0).(gols.Location), args.Error(1)
}

func (m *mockLSPClient) CheckCode(code string) (bool, string) {
	args := m.Called(code)
	return args.Bool(0), args.String(1)
}

func (m *mockLSPClient) Close() error {
	args := m.Called()
	return args.Error(0)
}

func TestKaziContextStore_GetSymbol(t *testing.T) {
	// Create a mock LSP client
	mockClient := new(mockLSPClient)

	// Create a test store
	store := NewKaziContextStore(StoreConfig{
		Workspace:    "testdata",
		ScanInterval: 30,
		LSPClient:    mockClient,
	})

	// Create a test symbol context
	testSymbol := &types.SymbolContext{
		Name:      "TestFunc",
		Kind:      types.KindFunction,
		DocString: "Test function documentation",
	}

	// Add the test symbol to the store's code context
	store.(*KaziContextStore).codeCtx.Files["test.go"] = &types.FileContext{
		FilePath: "test.go",
		Symbols:  map[string]*types.SymbolContext{"TestFunc": testSymbol},
	}

	// Test getting an existing symbol
	result := store.GetSymbol("TestFunc")
	assert.Equal(t, testSymbol, result)

	// Test getting a non-existent symbol
	result = store.GetSymbol("NonExistentFunc")
	assert.Nil(t, result)
}

func TestKaziContextStore_GetFile(t *testing.T) {
	// Create a mock LSP client
	mockClient := new(mockLSPClient)

	// Create a test store
	store := NewKaziContextStore(StoreConfig{
		Workspace:    "testdata",
		ScanInterval: 30,
		LSPClient:    mockClient,
	})

	// Create a test file context
	testFile := &types.FileContext{
		FilePath: "test.go",
		Symbols: map[string]*types.SymbolContext{
			"TestFunc": {
				Name:      "TestFunc",
				Kind:      types.KindFunction,
				DocString: "Test function documentation",
			},
		},
	}

	// Add the test file to the store's code context
	store.(*KaziContextStore).codeCtx.Files["test.go"] = testFile

	// Test getting an existing file
	result := store.GetFile("test.go")
	assert.Equal(t, testFile, result)

	// Test getting a non-existent file
	result = store.GetFile("nonexistent.go")
	assert.Nil(t, result)
}

func TestKaziContextStore_BuildOrRefresh(t *testing.T) {
	// Create a mock LSP client
	mockClient := new(mockLSPClient)

	// Set up mock expectations
	mockClient.On("GetFileContent", "test.go").Return("package test\n\nfunc TestFunc() {}", nil)
	mockClient.On("CheckCode", mock.Anything).Return(true, "")
	mockClient.On("GetWorkspaceSymbols", mock.Anything).Return([]gols.WorkspaceSymbol{
		{
			Name: "TestFunc",
			Kind: "function",
			Location: gols.Location{
				URI: "test.go",
				Range: gols.Range{
					Start: gols.Position{Line: 2, Character: 0},
					End:   gols.Position{Line: 2, Character: 20},
				},
			},
		},
	}, nil)
	mockClient.On("GetSymbolDocumentation", mock.Anything, mock.Anything).Return("Test function documentation", nil)
	mockClient.On("GetSymbolDefinition", mock.Anything, mock.Anything).Return(&gols.SymbolDefinition{
		Signature: "func TestFunc()",
	}, nil)
	mockClient.On("GetReferences", mock.Anything).Return([]string{"test.go"}, nil)
	mockClient.On("GetSymbolLocation", mock.Anything, mock.Anything).Return(gols.Location{
		URI: "test.go",
		Range: gols.Range{
			Start: gols.Position{Line: 2, Character: 0},
			End:   gols.Position{Line: 2, Character: 20},
		},
	}, nil)

	// Create a test store
	store := NewKaziContextStore(StoreConfig{
		Workspace:    "testdata",
		ScanInterval: 30,
		LSPClient:    mockClient,
	})

	// Test building the context
	err := store.BuildOrRefresh(context.Background())
	assert.NoError(t, err)

	// Verify that the mock expectations were met
	mockClient.AssertExpectations(t)

	// Test that the context was built correctly
	result := store.GetSymbol("TestFunc")
	assert.NotNil(t, result)
	assert.Equal(t, "TestFunc", result.Name)
	assert.Equal(t, types.KindFunction, result.Kind)
	assert.Equal(t, "Test function documentation", result.DocString)
}

// stringSliceEqual returns true if two string slices have the same elements in the same order
func stringSliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
