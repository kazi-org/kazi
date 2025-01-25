// Package openai provides an implementation of the ai.LLMClient interface using OpenAI's API.
package openai

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/kazi-org/kazi/internal/ai"
	openai "github.com/sashabaranov/go-openai"
)

// Client is a real client using go-openai
type Client struct {
	client *openai.Client
	model  string
}

// ClientOption is a function that modifies the OpenAI client configuration
type ClientOption func(*openai.ClientConfig)

// WithBaseURL sets a custom base URL for the OpenAI client
func WithBaseURL(url string) ClientOption {
	return func(config *openai.ClientConfig) {
		config.BaseURL = url
	}
}

// getModelFromEnv gets the model from environment variable or returns default
func getModelFromEnv() string {
	model := os.Getenv("OPENAI_MODEL")
	if model == "" {
		return "o1-mini" // Default to o1-mini
	}
	return model
}

// NewClient creates a new OpenAI client
func NewClient(opts ...ClientOption) (ai.LLMClient, error) {
	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		return nil, fmt.Errorf("missing OPENAI_API_KEY env")
	}
	config := openai.DefaultConfig(apiKey)
	for _, opt := range opts {
		opt(&config)
	}
	cli := openai.NewClientWithConfig(config)
	return &Client{
		client: cli,
		model:  getModelFromEnv(),
	}, nil
}

// GetPatch implements the ai.LLMClient interface
func (o *Client) GetPatch(ctx context.Context, prompt string) (string, error) {
	resp, err := o.client.CreateChatCompletion(
		ctx,
		openai.ChatCompletionRequest{
			Model: o.model,
			Messages: []openai.ChatCompletionMessage{
				{
					Role:    openai.ChatMessageRoleUser,
					Content: prompt,
				},
			},
		},
	)
	if err != nil {
		return "", fmt.Errorf("create chat completion: %w", err)
	}

	// Check for empty response
	if len(resp.Choices) == 0 {
		return "", fmt.Errorf("no choices from LLM")
	}

	// Get content from first choice
	content := resp.Choices[0].Message.Content

	// Validate content is valid JSON with all required fields
	var patchSet struct {
		Commit struct {
			Subject string `json:"subject"`
			Body    string `json:"body,omitempty"`
		} `json:"commit"`
		Patches []struct {
			File        string   `json:"file"`
			Type        string   `json:"type"`
			FromLine    int      `json:"fromLine"`
			ToLine      int      `json:"toLine"`
			Content     string   `json:"content"`
			LinesBefore []string `json:"linesBefore"`
			LinesAfter  []string `json:"linesAfter"`
		} `json:"patches"`
	}
	if err := json.Unmarshal([]byte(content), &patchSet); err != nil {
		return "", fmt.Errorf("invalid patch JSON: %w", err)
	}

	// Validate required fields
	if patchSet.Commit.Subject == "" {
		return "", fmt.Errorf("missing required field: commit.subject")
	}
	if len(patchSet.Patches) == 0 {
		return "", fmt.Errorf("missing required field: patches")
	}
	for i, p := range patchSet.Patches {
		if p.File == "" {
			return "", fmt.Errorf("missing required field: patches[%d].file", i)
		}
		if p.Type == "" {
			return "", fmt.Errorf("missing required field: patches[%d].type", i)
		}
		if p.Type == "replace" {
			if p.FromLine <= 0 {
				return "", fmt.Errorf("invalid fromLine in patch %d: must be > 0", i)
			}
			if p.ToLine < p.FromLine {
				return "", fmt.Errorf("invalid toLine in patch %d: must be >= fromLine", i)
			}
			if len(p.LinesBefore) == 0 {
				return "", fmt.Errorf("missing required field: patches[%d].linesBefore", i)
			}
			if len(p.LinesAfter) == 0 {
				return "", fmt.Errorf("missing required field: patches[%d].linesAfter", i)
			}
		}
		if p.Type != "delete" && p.Content == "" {
			return "", fmt.Errorf("missing required field: patches[%d].content", i)
		}
	}

	return content, nil
}

// patchStream implements io.ReadCloser for streaming patches
type patchStream struct {
	stream *openai.ChatCompletionStream
	buf    strings.Builder
}

func (s *patchStream) Read(p []byte) (n int, err error) {
	response, err := s.stream.Recv()
	if err != nil {
		if err == io.EOF {
			// Before returning EOF, validate the accumulated JSON
			content := s.buf.String()
			var patches struct {
				Patches []struct {
					File    string `json:"file"`
					Type    string `json:"type"`
					Content string `json:"content"`
				} `json:"patches"`
			}
			if err := json.Unmarshal([]byte(content), &patches); err != nil {
				return 0, fmt.Errorf("invalid patch JSON: %w", err)
			}
		}
		return 0, err
	}

	if len(response.Choices) == 0 {
		return 0, fmt.Errorf("no choices from LLM")
	}

	content := response.Choices[0].Delta.Content
	s.buf.WriteString(content)

	return copy(p, []byte(content)), nil
}

func (s *patchStream) Close() error {
	return s.stream.Close()
}

// StreamPatch implements the ai.LLMClient interface
func (o *Client) StreamPatch(ctx context.Context, prompt string) (io.ReadCloser, error) {
	stream, err := o.client.CreateChatCompletionStream(
		ctx,
		openai.ChatCompletionRequest{
			Model: o.model,
			Messages: []openai.ChatCompletionMessage{
				{
					Role:    openai.ChatMessageRoleUser,
					Content: prompt,
				},
			},
			Stream: true,
		},
	)
	if err != nil {
		return nil, fmt.Errorf("create chat completion stream: %w", err)
	}

	return &patchStream{stream: stream}, nil
}
