package ai

import (
	"context"
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
	// For demonstration, we do a ChatCompletion.
	// Real usage might do a text completion with special instructions for JSON output.
	resp, err := o.client.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
		Model: openai.F(openai.ChatModelGPT3_5Turbo),
		Messages: openai.F([]openai.ChatCompletionMessageParamUnion{
			openai.UserMessage(prompt),
		}),
	})
	if err != nil {
		return "", err
	}
	if len(resp.Choices) == 0 {
		return "", fmt.Errorf("no choices from LLM")
	}
	return resp.Choices[0].Message.Content, nil
}
