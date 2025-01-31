# project

The **project** package merges domain/vision details, operational config,
and optional doc (memory) references into a **single** cohesive model.

## Key Responsibilities

1. **Domain Contract** (Name, Description, Constraints)
2. **Architecture** (modules, interfaces)
3. **Config** (lint/test commands, workspace)
4. **Doc-Related** (optional references to doc files or user instructions)

By merging these, we avoid scattering "vision" vs. "config" vs. "blueprint" 
across multiple packages, simplifying developer mental load.

## Typical Flow

- The `Manager` interface can `LoadProject` from a YAML file or other source,
  returning a single `Project` struct that includes domain constraints, architecture,
  and config in one place.
- `coordinator` then queries `project` for data to feed the LLM or chunk code.
- If you want to store doc files or ephemeral logs, you can incorporate them 
  directly or reference separate logic.

