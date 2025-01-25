package openai

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestNewClient(t *testing.T) {
	// Save original env and restore after test
	origKey := os.Getenv("OPENAI_API_KEY")
	defer os.Setenv("OPENAI_API_KEY", origKey)

	tests := []struct {
		name    string
		apiKey  string
		wantErr bool
	}{
		{
			name:    "Valid API key",
			apiKey:  "test-key",
			wantErr: false,
		},
		{
			name:    "Missing API key",
			apiKey:  "",
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			os.Setenv("OPENAI_API_KEY", tc.apiKey)
			client, err := NewClient()
			if tc.wantErr {
				if err == nil {
					t.Error("expected error but got nil")
				}
				return
			}
			if err != nil {
				t.Errorf("unexpected error: %v", err)
			}
			if client == nil {
				t.Error("expected client but got nil")
			}
		})
	}
}

func TestGetPatch(t *testing.T) {
	// Create test server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify request
		if r.Method != http.MethodPost {
			t.Errorf("expected POST request, got %s", r.Method)
		}
		if !strings.HasSuffix(r.URL.Path, "/chat/completions") {
			t.Errorf("expected path to end with /chat/completions, got %s", r.URL.Path)
		}

		// Write response
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{
			"id": "test-id",
			"object": "chat.completion",
			"created": 1234567890,
			"model": "gpt-4",
			"choices": [
				{
					"message": {
						"role": "assistant",
						"content": "{\"patches\":[{\"file\":\"test.go\",\"type\":\"create\",\"content\":\"package main\"}]}"
					},
					"finish_reason": "stop",
					"index": 0
				}
			]
		}`)
	}))
	defer server.Close()

	// Create client with test server
	os.Setenv("OPENAI_API_KEY", "test-key")
	client, err := NewClient(WithBaseURL(server.URL))
	if err != nil {
		t.Fatalf("failed to create client: %v", err)
	}

	// Test GetPatch
	resp, err := client.GetPatch(context.Background(), "test prompt")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify response
	var patches struct {
		Patches []struct {
			File    string `json:"file"`
			Type    string `json:"type"`
			Content string `json:"content"`
		} `json:"patches"`
	}
	if err := json.Unmarshal([]byte(resp), &patches); err != nil {
		t.Fatalf("invalid JSON response: %v", err)
	}
	if len(patches.Patches) != 1 {
		t.Errorf("expected 1 patch, got %d", len(patches.Patches))
	}
}

func TestStreamPatch(t *testing.T) {
	// Create test server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify request
		if r.Method != http.MethodPost {
			t.Errorf("expected POST request, got %s", r.Method)
		}
		if !strings.HasSuffix(r.URL.Path, "/chat/completions") {
			t.Errorf("expected path to end with /chat/completions, got %s", r.URL.Path)
		}

		// Write response in chunks
		w.Header().Set("Content-Type", "text/event-stream")
		chunks := []string{
			`{"id":"1","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{"delta":{"role":"assistant","content":"{\"patches\":["}}]}`,
			`{"id":"2","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{"delta":{"content":"{\"file\":\"test.go\",\"type\":\"create\",\"content\":\"package main\"}"}}]}`,
			`{"id":"3","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{"delta":{"content":"]"}}]}`,
			`{"id":"4","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4","choices":[{"delta":{"content":"}"}}]}`,
		}

		for _, chunk := range chunks {
			fmt.Fprintf(w, "data: %s\n\n", chunk)
		}
		fmt.Fprintf(w, "data: [DONE]\n\n")
	}))
	defer server.Close()

	// Create client with test server
	os.Setenv("OPENAI_API_KEY", "test-key")
	client, err := NewClient(WithBaseURL(server.URL))
	if err != nil {
		t.Fatalf("failed to create client: %v", err)
	}

	// Test StreamPatch
	stream, err := client.StreamPatch(context.Background(), "test prompt")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer stream.Close()

	// Read and verify response
	var buf strings.Builder
	_, err = io.Copy(&buf, stream)
	if err != nil {
		t.Fatalf("failed to read stream: %v", err)
	}

	// Verify JSON
	var patches struct {
		Patches []struct {
			File    string `json:"file"`
			Type    string `json:"type"`
			Content string `json:"content"`
		} `json:"patches"`
	}
	if err := json.Unmarshal([]byte(buf.String()), &patches); err != nil {
		t.Fatalf("invalid JSON response: %v", err)
	}
	if len(patches.Patches) != 1 {
		t.Errorf("expected 1 patch, got %d", len(patches.Patches))
	}
}
