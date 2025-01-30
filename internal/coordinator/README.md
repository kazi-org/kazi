# coordinator

The `coordinator` package orchestrates the entire Kazi workflow:
1. Loads the Vision Contract and Architecture details.
2. Prepares prompts for the LLM, referencing the code chunks.
3. Receives minimal patches from the LLM.
4. Applies and validates patches, committing them if successful.

## Core Type

- **Coordinator**: The main interface with a `ProcessPrompt` method that
  runs the entire loop from prompt to validation.
