package gols

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

func (m *mockLSPClient) GetSymbolDocumentation(uri string, symbolName string) (string, error) {
	args := m.Called(uri, symbolName)
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

func TestGoClient(t *testing.T) {
	// Create temp workspace
	tmpDir, err := os.MkdirTemp("", "gols-test")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Initialize Go module
	err = os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(`module test

go 1.23.5
`), 0644)
	assert.NoError(t, err)

	// Create test file
	testFile := filepath.Join(tmpDir, "test.go")
	err = os.WriteFile(testFile, []byte(`package test

const TestConst = "test"
var TestVar = "test"

type TestType struct {
	Field string
}

func TestFunc(s string) string {
	return s
}

func main() {
	_ = TestFunc(TestConst)
	var t TestType
	t.Field = TestVar
}
`), 0644)
	if err != nil {
		t.Fatalf("Failed to write test file: %v", err)
	}

	// Change to temp directory
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Failed to get current directory: %v", err)
	}
	defer os.Chdir(origDir)

	err = os.Chdir(tmpDir)
	if err != nil {
		t.Fatalf("Failed to change directory: %v", err)
	}

	// Create client
	client, err := NewGoClient(context.Background(), tmpDir)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}

	// Test GetWorkspaceSymbols
	symbols, err := client.GetWorkspaceSymbols("")
	if err != nil {
		t.Errorf("GetWorkspaceSymbols failed: %v", err)
	}
	if len(symbols) == 0 {
		t.Error("Expected symbols but got none")
	}

	// Test GetSymbolDocumentation
	doc, err := client.GetSymbolDocumentation(testFile, "TestFunc")
	if err != nil {
		t.Logf("GetSymbolDocumentation warning: %v", err)
	}
	if doc != "" && !strings.Contains(doc, "TestFunc") {
		t.Errorf("Expected documentation to contain TestFunc, got %q", doc)
	}

	// Test GetReferences
	refs, err := client.GetReferences(testFile, "TestConst")
	if err != nil {
		t.Logf("GetReferences warning: %v", err)
	}
	if len(refs) == 0 {
		t.Log("No references found for TestConst")
	}

	// Test GetSymbolDefinition
	def, err := client.GetSymbolDefinition(testFile, "TestType")
	if err != nil {
		t.Logf("GetSymbolDefinition warning: %v", err)
	}
	if def != nil && def.Name != "TestType" {
		t.Errorf("Expected TestType, got %q", def.Name)
	}

	// Test GetFileContent
	content, err := client.GetFileContent(testFile)
	if err != nil {
		t.Errorf("GetFileContent failed: %v", err)
	}
	if !strings.Contains(content, "package test") {
		t.Errorf("Expected file content to contain package test, got %q", content)
	}

	// Test CheckCode
	valid, err := client.CheckCode("package test\n\nfunc main() {}")
	if err != nil {
		t.Errorf("CheckCode failed: %v", err)
	}
	if !valid {
		t.Error("Expected valid code")
	}
}
