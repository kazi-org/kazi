// Package contextstore provides functionality for managing code context.
package contextstore

import (
	"context"
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

	mockClient := new(mockLSPClient)
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
