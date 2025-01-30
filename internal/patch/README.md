# patch

The `patch` package handles the **minimal patch-based editing** approach:
the LLM returns a structured JSON describing which lines to add/replace/delete, 
and we apply them to the local codebase.

## Key Types

- **PatchSet**: A collection of patch operations.
- **Applier**: Applies patches to files on disk.

This ensures small, verifiable changes, reducing "runaway hallucinations" by 
only allowing the LLM to manipulate code line by line.
