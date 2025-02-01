# internal/patch

Minimal patch-based editing approach. The LLM returns a `PatchSet` describing line-level or 
file-based edits. We apply them locally. 

## Single Responsibility

- Only handle code modifications. 
- `PatchSet.Subject` can hold instructions (like "NEED_MEMORY: code:UserRepo") 
  or "RUN_CMD: grep ...", which the coordinator might parse.

