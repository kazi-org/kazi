# internal/coordinator

Coordinates the AI-driven code changes. It references:

- **MemoryAggregator** (or specialized code/doc/log sources) for context retrieval
- **runner.ExecRunner** for local command usage
- **patch.Applier** to apply changes
- **validator.Pipeline** to test/lint
- An **LLM** implementing `PatchGenerator`

## Single Responsibility

- Only orchestrates prompt -> patch -> apply -> validate, 
  delegating to memory, runner, patch, and validator.
