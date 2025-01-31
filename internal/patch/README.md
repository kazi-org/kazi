# patch

The **patch** package provides a minimal patch-based editing system to handle 
“small, verifiable changes” within the Kazi workflow. It includes:

1. **Data Structures** – `PatchSet` and `PatchOperation` describing line-based 
   creates, replaces, or deletes, and enumerations for `PatchType`.
2. **Applier** – An interface for applying patch sets to the codebase, with a 
   default implementation that can handle multiple patches concurrently.
3. **Validator** – An optional interface that checks whether a patch can safely be applied 
   before actually modifying files, catching out-of-range line numbers or mismatch contexts.
4. **Rollbacker** – An optional interface for reverting changes if partial application fails.
5. **FileManager** – A specialized interface ensuring the rest of the system depends on 
   abstractions (DIP) rather than direct filesystem calls.

## Why Patch-Based Editing?

Small line-based patches reduce the risk of “runaway hallucinations,” ensuring 
the LLM or user only modifies code in small increments. This package is generic 
enough to handle any text-based files, not just Go code.

## Key Principles

- **Single Responsibility**: Each file focuses on one piece (data, applying, validation, rollback, file I/O).
- **Open-Closed**: You can extend with new patch types or new Applier/Validator 
  implementations without modifying the existing logic.
- **Interface Segregation**: We keep `Applier`, `Validator`, `Rollbacker`, 
  and `FileManager` separate, each doing exactly one job.
- **Dependency Inversion**: The default patch logic uses a `FileManager` interface 
  to handle I/O—no direct calls to `os.*`, so we can swap in memory or remote backends.
- **Explicit Error Handling**: All methods that can fail return `error`.
- **Concurrent**: The default Applier can spawn goroutines to handle each patch operation 
  if desired, then gather results via channels.

Use these building blocks in your Kazi coordinator or logic for safe, incremental code edits.
