# coordinator

Orchestrates the prompt -> LLM -> patch -> validation flow. 
References:
- `memory` aggregator for code/docs/log retrieval
- `runner` for whitelisted local commands
- `patch` for code edits
- `validator` for build/test checks
