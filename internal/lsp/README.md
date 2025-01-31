# lsp

Provides Language Server Protocol (LSP) integration or any code-analysis 
services that help the LLM or user. For instance, you can use the LSP 
to build a "repo map", chunk the code for the LLM, perform symbol queries, etc.

## Example Usage

- Summon `AnalyzeFile` to find issues or gather line references.
- `FormatCode` for consistent style before/after patching.
- Possibly store an internal "repo map" of all files/lines to feed the LLM 
  in smaller chunks.

