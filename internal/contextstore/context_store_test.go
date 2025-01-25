package contextstore

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	lsp "github.com/kazi-org/kazi/internal/lsp/go"
)

// mockLSPClient implements lsp.LSPClient for testing
type mockLSPClient struct {
	symbols     []lsp.WorkspaceSymbol
	docStrings  map[string]string
	definitions map[string]*lsp.SymbolDefinition
	references  map[string][]string
}

func (m *mockLSPClient) GetWorkspaceSymbols(query string) ([]lsp.WorkspaceSymbol, error) {
	return m.symbols, nil
}

func (m *mockLSPClient) GetSymbolDocumentation(file, symbol string) (string, error) {
	return m.docStrings[symbol], nil
}

func (m *mockLSPClient) GetReferences(symbol string) ([]string, error) {
	return m.references[symbol], nil
}

func (m *mockLSPClient) GetSymbolDefinition(file, symbol string) (*lsp.SymbolDefinition, error) {
	def, ok := m.definitions[symbol]
	if !ok {
		return nil, fmt.Errorf("symbol %q not found", symbol)
	}
	return def, nil
}

func (m *mockLSPClient) GetFileContent(file string) (string, error) {
	if strings.Contains(file, "invalid.go") {
		return "invalid go code", nil
	}
	if strings.Contains(file, "main.go") {
		return "package main\n\nfunc main() {}\n", nil
	}
	if strings.Contains(file, "types.go") || strings.Contains(file, "funcs.go") {
		return "package example\n\nfunc main() {}\n", nil
	}
	return "", fmt.Errorf("file not found: %s", file)
}

func (m *mockLSPClient) GetSymbolLocation(file, symbol string) (lsp.Location, error) {
	return lsp.Location{}, nil
}

func (m *mockLSPClient) CheckCode(code string) (bool, string) {
	// For testing, we'll consider any code that starts with "package" as valid
	if strings.HasPrefix(strings.TrimSpace(code), "package") {
		return true, ""
	}
	return false, "invalid Go code"
}

func (m *mockLSPClient) Close() error {
	return nil
}

func TestKaziContextStore_BuildOrRefresh(t *testing.T) {
	tests := []struct {
		name        string
		files       map[string]string
		wantSymbols map[string]SymbolContext
		wantErr     bool
		errContains string
	}{
		{
			name: "Single Go file with function",
			files: map[string]string{
				"main.go": `package main

// HelloWorld prints a greeting
func HelloWorld() {
	println("Hello, World!")
}
`,
			},
			wantSymbols: map[string]SymbolContext{
				"HelloWorld": {
					Name:       "HelloWorld",
					Kind:       "function",
					DocString:  "HelloWorld prints a greeting\n",
					StartLine:  4,
					EndLine:    6,
					Package:    "main",
					Exported:   true,
					Signature:  "func HelloWorld()",
					References: []string{"main.go"},
				},
			},
		},
		{
			name: "Multiple files with types and functions",
			files: map[string]string{
				"types.go": `package example

// User represents a user in the system
type User struct {
	Name string
	Age  int
}

// unexportedType is not exported
type unexportedType struct{}
`,
				"funcs.go": `package example

// GetUser returns a new user
func GetUser(name string) *User {
	return &User{Name: name}
}
`,
			},
			wantSymbols: map[string]SymbolContext{
				"User": {
					Name:      "User",
					Kind:      "type",
					DocString: "User represents a user in the system\n",
					Package:   "example",
					Exported:  true,
				},
				"GetUser": {
					Name:      "GetUser",
					Kind:      "function",
					DocString: "GetUser returns a new user\n",
					Package:   "example",
					Exported:  true,
					Signature: "func GetUser(name string) *User",
				},
			},
		},
		{
			name: "Invalid Go file",
			files: map[string]string{
				"invalid.go": `package main

func invalid syntax {
`,
			},
			wantErr:     true,
			errContains: "parse Go file invalid.go",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create temporary workspace
			tmpDir, err := os.MkdirTemp("", "kazi-context-test-*")
			if err != nil {
				t.Fatalf("Failed to create temp dir: %v", err)
			}
			defer os.RemoveAll(tmpDir)

			// Write test files
			for name, content := range tc.files {
				path := filepath.Join(tmpDir, name)
				if err := os.WriteFile(path, []byte(content), 0644); err != nil {
					t.Fatalf("Failed to write file %s: %v", name, err)
				}
			}

			// Create mock LSP client with test data
			mockClient := &mockLSPClient{
				symbols: []lsp.WorkspaceSymbol{
					{
						Name: "HelloWorld",
						Kind: "function",
						Location: lsp.Location{
							URI: "main.go",
							Range: lsp.Range{
								Start: lsp.Position{Line: 3},
								End:   lsp.Position{Line: 5},
							},
						},
					},
					{
						Name: "User",
						Kind: "type",
						Location: lsp.Location{
							URI: "types.go",
							Range: lsp.Range{
								Start: lsp.Position{Line: 3},
								End:   lsp.Position{Line: 5},
							},
						},
					},
					{
						Name: "GetUser",
						Kind: "function",
						Location: lsp.Location{
							URI: "funcs.go",
							Range: lsp.Range{
								Start: lsp.Position{Line: 3},
								End:   lsp.Position{Line: 4},
							},
						},
					},
				},
				docStrings: map[string]string{
					"HelloWorld": "HelloWorld prints a greeting\n",
					"User":       "User represents a user in the system\n",
					"GetUser":    "GetUser returns a new user\n",
				},
				definitions: map[string]*lsp.SymbolDefinition{
					"HelloWorld": &lsp.SymbolDefinition{Signature: "func HelloWorld()"},
					"User":       &lsp.SymbolDefinition{Signature: "type User struct"},
					"GetUser":    &lsp.SymbolDefinition{Signature: "func GetUser(name string) *User"},
				},
				references: map[string][]string{
					"HelloWorld": {"main.go"},
					"User":       {"types.go", "funcs.go"},
					"GetUser":    {"funcs.go"},
				},
			}

			// Create context store with mock client
			store := NewKaziContextStore(tmpDir, mockClient)
			err = store.BuildOrRefresh()

			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error but got nil")
				}
				if tc.errContains != "" && !contains(err.Error(), tc.errContains) {
					t.Errorf("error %q does not contain %q", err.Error(), tc.errContains)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			// Get and verify context
			ctx := store.GetCodeContext()
			if ctx == nil {
				t.Fatal("expected non-nil code context")
			}

			// Verify symbols
			for name, want := range tc.wantSymbols {
				var found bool
				var got *SymbolContext
				for _, fc := range ctx.Files {
					if s, ok := fc.Symbols[name]; ok {
						found = true
						got = s
						break
					}
				}
				if !found {
					t.Errorf("symbol %q not found", name)
					continue
				}

				// Compare fields that should always match
				if got.Name != want.Name {
					t.Errorf("symbol %q name = %q, want %q", name, got.Name, want.Name)
				}
				if got.Kind != want.Kind {
					t.Errorf("symbol %q kind = %q, want %q", name, got.Kind, want.Kind)
				}
				if got.DocString != want.DocString {
					t.Errorf("symbol %q doc = %q, want %q", name, got.DocString, want.DocString)
				}
				if got.Package != want.Package {
					t.Errorf("symbol %q package = %q, want %q", name, got.Package, want.Package)
				}
				if got.Exported != want.Exported {
					t.Errorf("symbol %q exported = %v, want %v", name, got.Exported, want.Exported)
				}

				// Compare optional fields only if specified in want
				if want.StartLine != 0 && got.StartLine != want.StartLine {
					t.Errorf("symbol %q start line = %d, want %d", name, got.StartLine, want.StartLine)
				}
				if want.EndLine != 0 && got.EndLine != want.EndLine {
					t.Errorf("symbol %q end line = %d, want %d", name, got.EndLine, want.EndLine)
				}
				if want.Signature != "" && got.Signature != want.Signature {
					t.Errorf("symbol %q signature = %q, want %q", name, got.Signature, want.Signature)
				}
				if len(want.References) > 0 && !stringSliceEqual(got.References, want.References) {
					t.Errorf("symbol %q references = %v, want %v", name, got.References, want.References)
				}
			}
		})
	}
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
