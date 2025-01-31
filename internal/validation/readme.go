# validation

The **validation** package implements a flexible pipeline of checks (lint, tests, security, etc.)  
that ensure patched or generated code meets project standards before final acceptance.

## Key Responsibilities

1. **Pipeline**: A unifying interface that runs any number of checks (commands, tools, or custom logic).
2. **Command-Based Validation**: By default, we can run `LintCommand` and `TestCommand` from the project's config.
3. **Concurrent Checks**: The pipeline can run multiple checks in parallel, speeding up validation.
4. **Results Aggregation**: Collect a structured result or an aggregated error message.

## Design Principles

- **Single Responsibility**: Each file focuses on one piece (the pipeline interface, command-based checks, concurrency, and result structures).
- **Open-Closed**: Adding new checks (like “SecurityScanCheck”) doesn't require rewriting the entire pipeline.
- **Liskov Substitution**: You can substitute any “Check” or “Pipeline” implementation without breaking the system.
- **Interface Segregation**: We keep the Pipeline interface minimal, plus smaller specialized interfaces (like a “Check”).
- **Dependency Inversion**: The pipeline depends on abstract “Check” logic, not direct shell or test code.
- **Composition Over Inheritance**: We compose checks in a pipeline aggregator, avoiding subclass trees.
- **Concurrency**: The concurrency file demonstrates how to run multiple checks in parallel using channels/goroutines.
- **Explicit Errors**: All methods that may fail return `error` or structured results with error info.
- **Small, Focused**: Each file is short and targeted.

## Typical Flow

1. **Create or load** a pipeline that has references to each “Check” (like LintCheck, TestCheck).
2. **Run** `ValidateAll()` from the pipeline, which:
   - Possibly runs checks in parallel.
   - Aggregates results or stops on the first failure, depending on your preference.
3. **Return** a structured result or an error.  
4. The coordinator or patch logic uses this result to decide whether to commit changes.

