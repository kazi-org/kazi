package workflow

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/kazi-org/kazi/internal/config"
	"github.com/kazi-org/kazi/internal/patch"
)

// defaultInteraction is the default implementation of UserInteraction
type defaultInteraction struct {
	reader *bufio.Reader
}

// NewDefaultInteraction creates a new default user interaction
func NewDefaultInteraction() UserInteraction {
	return &defaultInteraction{
		reader: bufio.NewReader(os.Stdin),
	}
}

// PromptForChanges asks the user to accept or reject changes
func (d *defaultInteraction) PromptForChanges(ctx context.Context, changes *patch.PatchSet) (UserInteractionMode, *config.Prompt, error) {
	// Show changes
	fmt.Println("\nProposed changes:")
	for _, p := range changes.Patches {
		fmt.Printf("- %s: %s\n", p.Type, p.File)
	}

	// Show commit message
	fmt.Printf("\nCommit message:\n%s\n", changes.Commit.Subject)
	if changes.Commit.Body != "" {
		fmt.Printf("\n%s\n", changes.Commit.Body)
	}

	// Show options
	fmt.Println("\nOptions:")
	fmt.Println("- yes    : accept current changes")
	fmt.Println("- no     : reject current changes")
	fmt.Println("- chat   : modify the prompt and try again")
	fmt.Println("- abort  : abort the entire operation")
	fmt.Println("- all    : accept all changes in current prompt")
	fmt.Println("- yolo   : accept all changes in all prompts")

	for {
		select {
		case <-ctx.Done():
			return 0, nil, ctx.Err()
		default:
			fmt.Print("\nYour choice: ")
			input, err := d.reader.ReadString('\n')
			if err != nil {
				return 0, nil, fmt.Errorf("read user input: %w", err)
			}

			choice := strings.TrimSpace(strings.ToLower(input))
			switch choice {
			case "yes", "y":
				return ModeYes, nil, nil
			case "no", "n":
				return ModeNo, nil, nil
			case "chat", "c":
				fmt.Print("\nEnter new prompt: ")
				input, err := d.reader.ReadString('\n')
				if err != nil {
					return 0, nil, fmt.Errorf("read prompt: %w", err)
				}
				return ModeChat, &config.Prompt{Instructions: strings.TrimSpace(input)}, nil
			case "abort", "a":
				return ModeAbort, nil, nil
			case "all":
				return ModeAll, nil, nil
			case "yolo":
				return ModeYolo, nil, nil
			default:
				fmt.Println("Invalid choice. Please try again.")
			}
		}
	}
}
