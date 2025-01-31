# coordinator

Orchestrates the "prompt -> LLM -> patch -> validation" cycle. 

## Key Steps

1. **Load/Update Project**: The coordinator queries `project.Manager` to get 
   or update the full system context (domain constraints, architecture, config).
2. **LLM Prompt**: Summarizes the Project and relevant code chunks (via `ProvideChunks`) 
   for the LLM to generate a patch.
3. **Patch Application**: Calls `patch.Applier` to apply the minimal changes.
4. **Validation**: Invokes `validation.Pipeline` to ensure code quality. 
   If success, commit or finalize. If failure, revert or prompt user.

