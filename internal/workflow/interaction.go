package workflow

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/go-git/go-git/v5/plumbing/color"
	"github.com/go-git/go-git/v5/plumbing/format/diff"
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

// displayColoredDiff shows a colored diff of the changes
func (d *defaultInteraction) displayColoredDiff(changes *patch.PatchSet) {
	// Create color config with default colors
	cc := diff.NewColorConfig()

	// Display each patch
	for _, p := range changes.Patches {
		// Print file header
		fmt.Printf("%s%sdiff --git a/%s b/%s%s\n",
			cc[diff.Meta], color.Bold,
			p.File, p.File,
			cc.Reset(diff.Meta))

		// Print file mode changes based on patch type
		switch p.Type {
		case "create":
			fmt.Printf("%snew file mode 100644%s\n", cc[diff.Meta], cc.Reset(diff.Meta))
		case "delete":
			fmt.Printf("%sdeleted file mode 100644%s\n", cc[diff.Meta], cc.Reset(diff.Meta))
		case "modify":
			fmt.Printf("%smodified file mode 100644%s\n", cc[diff.Meta], cc.Reset(diff.Meta))
		}

		// Print file paths
		fmt.Printf("%s--- a/%s%s\n", cc[diff.Meta], p.File, cc.Reset(diff.Meta))
		fmt.Printf("%s+++ b/%s%s\n", cc[diff.Meta], p.File, cc.Reset(diff.Meta))

		// Print content changes
		lines := strings.Split(p.Content, "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "+") {
				fmt.Printf("%s%s%s\n", cc[diff.New], line, cc.Reset(diff.New))
			} else if strings.HasPrefix(line, "-") {
				fmt.Printf("%s%s%s\n", cc[diff.Old], line, cc.Reset(diff.Old))
			} else if strings.HasPrefix(line, "@") {
				fmt.Printf("%s%s%s\n", cc[diff.Frag], line, cc.Reset(diff.Frag))
			} else {
				fmt.Printf("%s%s%s\n", cc[diff.Context], line, cc.Reset(diff.Context))
			}
		}
		fmt.Println()
	}
}

// PromptForChanges asks the user to accept or reject changes
func (d *defaultInteraction) PromptForChanges(ctx context.Context, changes *patch.PatchSet) (UserInteractionMode, string, error) {
	// Display colored diff
	d.displayColoredDiff(changes)

	// Show commit message
	fmt.Printf("\nProposed commit message:\n")
	fmt.Printf("%s%s%s\n", color.Bold, changes.Commit.Subject, color.Reset)
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
			return 0, "", ctx.Err()
		default:
			fmt.Print("\nYour choice: ")
			input, err := d.reader.ReadString('\n')
			if err != nil {
				return 0, "", fmt.Errorf("read user input: %w", err)
			}

			input = strings.TrimSpace(strings.ToLower(input))
			switch input {
			case "yes", "y":
				return ModeYes, "", nil
			case "no", "n":
				return ModeNo, "", nil
			case "chat", "c":
				fmt.Print("Enter new prompt: ")
				promptStr, err := d.reader.ReadString('\n')
				if err != nil {
					return 0, "", fmt.Errorf("read prompt: %w", err)
				}
				return ModeChat, strings.TrimSpace(promptStr), nil
			case "abort", "a":
				return ModeAbort, "", nil
			case "all":
				return ModeAll, "", nil
			case "yolo":
				return ModeYolo, "", nil
			default:
				fmt.Println("Invalid choice. Please try again.")
			}
		}
	}
}
