# validation

The `validation` package runs code checks in a single pipeline:
- Lint
- Unit/Integration Tests
- Security or style checks

A single `ValidateAll()` call ensures newly patched code meets project standards
before final acceptance.

## Key Types

- **Pipeline**: The main interface for running all checks.
- **DefaultPipeline**: An example implementation that runs commands from config.
