// Package openai provides an implementation of the ai.LLMClient interface using OpenAI's API.
package openai

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/kazi-org/kazi/internal/ai"
	openai "github.com/openai/openai-go"
	"github.com/openai/openai-go/option"
)

// Client is a real client using openai-go
type Client struct {
	apiKey string
	client *openai.Client
}

// NewClient creates a new OpenAI client
func NewClient() (ai.LLMClient, error) {
	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		return nil, fmt.Errorf("missing OPENAI_API_KEY env")
	}
	cli := openai.NewClient(option.WithAPIKey(apiKey))
	return &Client{
		apiKey: apiKey,
		client: cli,
	}, nil
}

// GetPatch implements the ai.LLMClient interface
func (o *Client) GetPatch(ctx context.Context, prompt string) (string, error) {
	// Create chat completion request
	resp, err := o.client.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
		Model: openai.F(openai.ChatModelGPT4),
		Messages: openai.F([]openai.ChatCompletionMessageParamUnion{
			openai.UserMessage(prompt),
		}),
	})
	if err != nil {
		return "", fmt.Errorf("create chat completion: %w", err)
	}

	// Check for empty response
	if len(resp.Choices) == 0 {
		return "", fmt.Errorf("no choices from LLM")
	}

	// Get content from first choice
	content := resp.Choices[0].Message.Content

	// Validate content is valid JSON
	var patches struct {
		Patches []struct {
			File    string `json:"file"`
			Type    string `json:"type"`
			Content string `json:"content"`
		} `json:"patches"`
	}
	if err := json.Unmarshal([]byte(content), &patches); err != nil {
		return "", fmt.Errorf("invalid patch JSON: %w", err)
	}

	return content, nil
}
