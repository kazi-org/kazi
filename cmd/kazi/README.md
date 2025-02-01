# cmd/kazi

**Purpose**: Provide a CLI subcommand structure for Kazi:
- `kazi init` 
- `kazi build`
- `kazi deploy`
- `kazi prompt "..."`

**Single Responsibility**: 
- Only parse CLI arguments and delegate to internal packages.

## Implementation

- Read subcommand from `os.Args[1]`.
- For “init,” you might call `project.DefaultProjectManager`.
- For “prompt,” create a coordinator with your specialized LLM and run `ProcessPrompt`.
- For “build,” call `validator.Pipeline` or other logic.
- For “deploy,” integrate a deployment approach.

