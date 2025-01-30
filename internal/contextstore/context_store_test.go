// Package contextstore provides functionality for managing code context.
package contextstore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kazi-org/kazi/internal/ls/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
)

// mockLSPClient implements LSPClient for testing
type mockLSPClient struct {
	mock.Mock
	fileContents map[string]string
}

func (m *mockLSPClient) GetWorkspaceSymbols(query string) ([]types.WorkspaceSymbol, error) {
	args := m.Called(query)
	return args.Get(0).([]types.WorkspaceSymbol), args.Error(1)
}

func (m *mockLSPClient) GetSymbolDocumentation(filePath, symbolName string) (string, error) {
	args := m.Called(filePath, symbolName)
	return args.String(0), args.Error(1)
}

func (m *mockLSPClient) GetReferences(filePath, symbolName string) ([]*types.Location, error) {
	args := m.Called(filePath, symbolName)
	return args.Get(0).([]*types.Location), args.Error(1)
}

func (m *mockLSPClient) GetSymbolDefinition(filePath, symbolName string) (*types.SymbolDefinition, error) {
	args := m.Called(filePath, symbolName)
	return args.Get(0).(*types.SymbolDefinition), args.Error(1)
}

func (m *mockLSPClient) GetFileContent(filePath string) (string, error) {
	args := m.Called(filePath)
	return args.String(0), args.Error(1)
}

func (m *mockLSPClient) GetSymbolLocation(filePath, symbolName string) (*types.Location, error) {
	args := m.Called(filePath, symbolName)
	return args.Get(0).(*types.Location), args.Error(1)
}

func (m *mockLSPClient) CheckCode(code string) (bool, error) {
	args := m.Called(code)
	return args.Bool(0), args.Error(1)
}

func (m *mockLSPClient) Close() error {
	args := m.Called()
	return args.Error(0)
}

func (m *mockLSPClient) FormatFile(filePath string) (string, error) {
	content, ok := m.fileContents[filePath]
	if !ok {
		return "", fmt.Errorf("file not found: %s", filePath)
	}
	return content, nil
}

func TestKaziContextStore(t *testing.T) {
	// Create test directory and file
	testDir := "testdata"
	err := os.MkdirAll(testDir, 0755)
	assert.NoError(t, err)
	defer os.RemoveAll(testDir)

	testFile := filepath.Join(testDir, "main.go")
	err = os.WriteFile(testFile, []byte(`package main

func main() {
	println("Hello, World!")
}
`), 0644)
	assert.NoError(t, err)

	// Create mock client with file contents
	mockClient := &mockLSPClient{
		fileContents: map[string]string{
			testFile: `package main

func main() {
	println("Hello, World!")
}`,
		},
	}

	// Set up mock expectations
	mockClient.On("GetFileContent", mock.Anything).Return(`package main

func main() {
	println("Hello, World!")
}`, nil)

	mockClient.On("GetWorkspaceSymbols", mock.Anything).Return([]types.WorkspaceSymbol{
		{
			Name: "main",
			Kind: types.KindFunction,
			Location: types.Location{
				URI: "main.go",
				Range: types.Range{
					Start: types.Position{Line: 3, Character: 1},
					End:   types.Position{Line: 3, Character: 5},
				},
			},
		},
	}, nil)

	mockClient.On("GetSymbolDocumentation", mock.Anything, mock.Anything).Return("main function", nil)

	mockClient.On("GetReferences", mock.Anything, mock.Anything).Return([]*types.Location{
		{
			URI: "main.go",
			Range: types.Range{
				Start: types.Position{Line: 3, Character: 1},
				End:   types.Position{Line: 3, Character: 5},
			},
		},
	}, nil)

	mockClient.On("GetSymbolDefinition", mock.Anything, mock.Anything).Return(&types.SymbolDefinition{
		Name:      "main",
		Kind:      types.KindFunction,
		URI:       "main.go",
		StartLine: 3,
		EndLine:   5,
		DocString: "main function",
	}, nil)

	mockClient.On("GetSymbolLocation", mock.Anything, mock.Anything).Return(&types.Location{
		URI: "main.go",
		Range: types.Range{
			Start: types.Position{Line: 3, Character: 1},
			End:   types.Position{Line: 3, Character: 5},
		},
	}, nil)

	mockClient.On("CheckCode", mock.Anything).Return(true, nil)
	mockClient.On("Close").Return(nil)

	// Create store with mock client
	store := NewKaziContextStore(StoreConfig{
		Workspace:    testDir,
		ScanInterval: 30,
		LSPClient:    mockClient,
	})

	// Build the code context
	err = store.BuildOrRefresh(context.Background())
	assert.NoError(t, err)

	// Test GetSymbol
	sym := store.GetSymbol("main")
	assert.NotNil(t, sym)
	assert.Equal(t, "main", sym.Name)
	assert.Equal(t, string(types.KindFunction), sym.Kind)

	// Test GetFile
	file := store.GetFile("main.go")
	assert.NotNil(t, file)
	assert.Equal(t, "main.go", file.FilePath)

	// Test GetCodeContext
	ctx := store.GetCodeContext()
	assert.NotNil(t, ctx)
	assert.Len(t, ctx.Files, 1)

	// Verify all mock expectations were met
	mockClient.AssertExpectations(t)
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
