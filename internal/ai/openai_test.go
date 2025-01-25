package ai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	openai "github.com/openai/openai-go"
	"github.com/openai/openai-go/option"
)

func TestOpenAIClient_GetPatch(t *testing.T) {
	tests := []struct {
		name        string
		prompt      string
		mockResp    string
		wantErr     bool
		errContains string
	}{
		{
			name:   "Valid response",
			prompt: "Add a function named Foo",
			mockResp: `{
				"id": "test-id",
				"object": "chat.completion",
				"created": 1234567890,
				"model": "gpt-4",
				"choices": [
					{
						"index": 0,
						"message": {
							"role": "assistant",
							"content": "{\"patches\":[{\"file\":\"main.go\",\"type\":\"create\",\"content\":\"package main\\n\\nfunc Foo() {\\n}\\n\"}]}"
						},
						"finish_reason": "stop"
					}
				]
			}`,
		},
		{
			name:   "Invalid JSON in response content",
			prompt: "Add a function",
			mockResp: `{
				"id": "test-id",
				"object": "chat.completion",
				"created": 1234567890,
				"model": "gpt-4",
				"choices": [
					{
						"index": 0,
						"message": {
							"role": "assistant",
							"content": "not a valid json patch"
						},
						"finish_reason": "stop"
					}
				]
			}`,
			wantErr:     true,
			errContains: "invalid character",
		},
		{
			name:   "Empty response",
			prompt: "Add a function",
			mockResp: `{
				"id": "test-id",
				"object": "chat.completion",
				"created": 1234567890,
				"model": "gpt-4",
				"choices": []
			}`,
			wantErr:     true,
			errContains: "no choices from LLM",
		},
		{
			name:        "Invalid response JSON",
			prompt:      "Add a function",
			mockResp:    "invalid json",
			wantErr:     true,
			errContains: "invalid character",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Create test server
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				// Verify request
				if r.Method != http.MethodPost {
					t.Errorf("expected POST request, got %s", r.Method)
				}
				if r.Header.Get("Content-Type") != "application/json" {
					t.Errorf("expected Content-Type application/json, got %s", r.Header.Get("Content-Type"))
				}
				if r.Header.Get("Authorization") == "" {
					t.Error("missing Authorization header")
				}

				// Send response
				w.Header().Set("Content-Type", "application/json")
				w.Write([]byte(tc.mockResp))
			}))
			defer server.Close()

			// Create client with test server URL
			client := &openAIClient{
				apiKey: "test-key",
				client: openai.NewClient(option.WithAPIKey("test-key"), option.WithBaseURL(server.URL)),
			}

			// Test GetPatch
			got, err := client.GetPatch(context.Background(), tc.prompt)
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

			// Verify response is valid JSON
			var patches struct {
				Patches []struct {
					File    string `json:"file"`
					Type    string `json:"type"`
					Content string `json:"content"`
				} `json:"patches"`
			}
			if err := json.Unmarshal([]byte(got), &patches); err != nil {
				t.Errorf("response is not valid JSON: %v", err)
			}
		})
	}
}

func TestNewOpenAIClient(t *testing.T) {
	tests := []struct {
		name        string
		envKey      string
		envValue    string
		wantErr     bool
		errContains string
	}{
		{
			name:     "Valid API key",
			envKey:   "OPENAI_API_KEY",
			envValue: "test-key",
		},
		{
			name:        "Missing API key",
			envKey:      "OPENAI_API_KEY",
			envValue:    "",
			wantErr:     true,
			errContains: "missing OPENAI_API_KEY env",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Set environment variable
			if tc.envValue != "" {
				os.Setenv(tc.envKey, tc.envValue)
				defer os.Unsetenv(tc.envKey)
			} else {
				os.Unsetenv(tc.envKey)
			}

			// Test NewOpenAIClient
			client, err := NewOpenAIClient()
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

			// Verify client fields
			oc, ok := client.(*openAIClient)
			if !ok {
				t.Fatal("client is not an openAIClient")
			}
			if oc.apiKey != tc.envValue {
				t.Errorf("apiKey = %q, want %q", oc.apiKey, tc.envValue)
			}
			if oc.client == nil {
				t.Error("openai client is nil")
			}
		})
	}
}

// contains checks if a string contains a substring
func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
