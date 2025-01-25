package lsp

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestGoClient(t *testing.T) {
	// Create temp workspace
	tmpDir, err := os.MkdirTemp("", "lsp-test")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Initialize Go module
	cmd := exec.Command("go", "mod", "init", "example.com/test")
	cmd.Dir = tmpDir
	if err := cmd.Run(); err != nil {
		t.Fatalf("Failed to initialize Go module: %v", err)
	}

	// Create test file
	mainFile := filepath.Join(tmpDir, "main.go")
	err = os.WriteFile(mainFile, []byte(`package main

// TestFunc is a test function
func TestFunc(x int) int {
	return x + 1
}

// TestType is a test type
type TestType struct {
	Field string
}

// TestConst is a test constant
const TestConst = 42

// TestVar is a test variable
var TestVar = "test"

func main() {
	_ = TestFunc(TestConst)
	var t TestType
	t.Field = TestVar
}
`), 0644)
	if err != nil {
		t.Fatalf("Failed to write test file: %v", err)
	}

	// Create client
	client, err := NewGoClient(context.Background(), tmpDir)
	if err != nil {
		t.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close()

	t.Run("GetWorkspaceSymbols", func(t *testing.T) {
		symbols, err := client.GetWorkspaceSymbols("Test")
		if err != nil {
			t.Fatalf("GetWorkspaceSymbols() error = %v", err)
		}
		if len(symbols) != 5 { // TestFunc, TestType, TestConst, TestVar, main
			t.Errorf("Expected 5 symbols, got %d", len(symbols))
		}
		// Check each symbol
		for _, s := range symbols {
			if !strings.HasPrefix(s.Name, "Test") && s.Name != "main" {
				t.Errorf("Unexpected symbol name: %s", s.Name)
			}
			if s.Location.URI == "" {
				t.Errorf("Symbol %s has empty location", s.Name)
			}
			switch s.Name {
			case "TestFunc":
				if s.Kind != "function" {
					t.Errorf("Expected TestFunc to be function, got %s", s.Kind)
				}
			case "TestType":
				if s.Kind != "type" {
					t.Errorf("Expected TestType to be type, got %s", s.Kind)
				}
			case "TestConst":
				if s.Kind != "constant" {
					t.Errorf("Expected TestConst to be constant, got %s", s.Kind)
				}
			case "TestVar":
				if s.Kind != "variable" {
					t.Errorf("Expected TestVar to be variable, got %s", s.Kind)
				}
			case "main":
				if s.Kind != "function" {
					t.Errorf("Expected main to be function, got %s", s.Kind)
				}
			default:
				t.Errorf("Unexpected symbol: %s", s.Name)
			}
		}
	})

	t.Run("GetSymbolDocumentation", func(t *testing.T) {
		doc, err := client.GetSymbolDocumentation("main.go", "TestFunc")
		if err != nil {
			t.Fatalf("GetSymbolDocumentation() error = %v", err)
		}
		if doc != "TestFunc is a test function" {
			t.Errorf("Expected 'TestFunc is a test function', got %q", doc)
		}
	})

	t.Run("GetReferences", func(t *testing.T) {
		refs, err := client.GetReferences("TestConst")
		if err != nil {
			t.Fatalf("GetReferences() error = %v", err)
		}
		if len(refs) < 1 {
			t.Error("Expected at least one reference")
		}
		// TestConst is referenced in main()
		found := false
		for _, ref := range refs {
			if filepath.Base(ref) == "main.go" {
				found = true
				break
			}
		}
		if !found {
			t.Error("Reference in main() not found")
		}
	})

	t.Run("GetSymbolDefinition", func(t *testing.T) {
		def, err := client.GetSymbolDefinition("main.go", "TestType")
		if err != nil {
			t.Fatalf("GetSymbolDefinition() error = %v", err)
		}
		if def.Name != "TestType" {
			t.Errorf("Expected name TestType, got %s", def.Name)
		}
		if def.Kind != "type" {
			t.Errorf("Expected kind type, got %s", def.Kind)
		}
	})

	t.Run("GetFileContent", func(t *testing.T) {
		content, err := client.GetFileContent(mainFile)
		if err != nil {
			t.Fatalf("GetFileContent() error = %v", err)
		}
		if len(content) == 0 {
			t.Error("Expected non-empty file content")
		}
	})

	t.Run("GetSymbolLocation", func(t *testing.T) {
		loc, err := client.GetSymbolLocation("main.go", "TestVar")
		if err != nil {
			t.Fatalf("GetSymbolLocation() error = %v", err)
		}
		if !strings.HasSuffix(loc.URI, "main.go") {
			t.Errorf("Expected URI to end with main.go, got %s", loc.URI)
		}
	})

	t.Run("CheckCode", func(t *testing.T) {
		t.Run("Valid code", func(t *testing.T) {
			ok, errMsg := client.CheckCode("package main\n\nfunc main() {}\n")
			if errMsg != "" {
				t.Fatalf("CheckCode() error = %v", errMsg)
			}
			if !ok {
				t.Error("CheckCode() = false, want true")
			}
		})

		t.Run("Invalid code", func(t *testing.T) {
			ok, errMsg := client.CheckCode("package main\n\nfunc main() {\n  x := 1\n  x = 'invalid'\n}\n")
			if errMsg == "" {
				t.Error("CheckCode() error = empty, want error message")
			}
			if ok {
				t.Error("CheckCode() = true, want false")
			}
		})
	})
}
