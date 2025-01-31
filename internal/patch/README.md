# patch

Handles minimal patch-based editing. The LLM outputs a PatchSet specifying
where to create, replace, or delete lines in the codebase. The patch logic
ensures small, targeted edits, reducing hallucination risk.

