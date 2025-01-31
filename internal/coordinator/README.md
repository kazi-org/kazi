# coordinator

This package implements the core orchestration logic for Kazi, bridging user prompts 
to code generation (LLM) and patch application, while standardizing how **context** 
flows to the LLM from multiple sources (like docs, domain constraints, ephemeral logs, 
chunk managers, etc.).

## New Concepts

1. **ContextClient**:  
   A small interface (`GetContext(key string)`) providing textual context for the LLM. 
   For example:
   - `DocContextClient` might retrieve doc content from memory or disk.
   - `DomainContextClient` might retrieve constraints from the project domain.
   - `EphemeralContextClient` might retrieve short-lived logs or next-step instructions.

2. **ContextAggregator**:  
   A specialized aggregator that merges contexts from multiple `ContextClient`s 
   into a single prompt chunk.

3. **Coordinator**:  
   Has the same overarching responsibility (prompt -> patch -> validation), 
   but calls the aggregator to build a final LLM prompt. It then calls the LLM,
   applies patches, runs validation, etc.

## Flow

1. The `Coordinator` gathers context from each `ContextClient` using some “keys”.
2. The coordinator calls an `LLMClient` to get a minimal `PatchSet`.
3. The coordinator applies patches (using `patch.Applier`) and runs `validation.Pipeline`.
4. If everything passes, we finalize or commit changes. If not, we revert or ask the user.

This design remains **simple** while being **powerful** enough to handle 
multiple context sources for the LLM or different LLM implementations 
without rewriting the coordinator logic.
