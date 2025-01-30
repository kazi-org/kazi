# vision

The `vision` package manages the **Vision Contract**, a single source of truth 
describing high-level product constraints and overarching requirements. This 
ensures the LLM stays aligned with production goals and domain rules.

## Types

- **Contract**: Holds key fields like project name, description, constraints.
- **(Optional) Loader**: Reads this contract from a YAML file or another source.

Use this in the coordinator or architecture steps to ensure code generation 
never strays from the intended domain logic.
