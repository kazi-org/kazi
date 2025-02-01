# internal/runner

A whitelisted local command runner, letting the LLM or coordinator run commands 
like `grep` or `ls` in a safe manner.

## Interfaces

- **ExecRunner**: Runs a command if it's in the allowlist
- **AllowedRunner**: Reference implementation storing allowed commands in a map

