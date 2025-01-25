package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	openai "github.com/openai/openai-go"
	"github.com/openai/openai-go/option"
)

// Simple interface we can mock for testing
type LLMClient interface {
	GetPatch(ctx context.Context, prompt string) (string, error)
}

// openAIClient is a real client using openai-go
type openAIClient struct {
	apiKey string
	client *openai.Client
}

func NewOpenAIClient() (LLMClient, error) {
	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		return nil, fmt.Errorf("missing OPENAI_API_KEY env")
	}
	cli := openai.NewClient(option.WithAPIKey(apiKey))
	return &openAIClient{
		apiKey: apiKey,
		client: cli,
	}, nil
}

func (o *openAIClient) GetPatch(ctx context.Context, prompt string) (string, error) {
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
