# architecture

The `architecture` package handles two major concerns:
1. Generating or maintaining a high-level **blueprint** of modules and interfaces.
2. **Chunking** the code so only relevant slices are passed to the LLM at once.

## Key Types

- **Architecture**: A minimal struct holding module specs.
- **Manager**: Builds the architecture (possibly from the Vision Contract) and 
  provides chunked code or relevant sections.

## Typical Use

The coordinator calls `architecture.Manager` to figure out how the codebase is structured
and retrieve partial code for LLM context. This helps keep the LLM from being overwhelmed
by large repos.
