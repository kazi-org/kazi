defmodule Kazi.HarnessAdapter do
  @moduledoc """
  The contract for driving a coding agent (the *inner loop*) — `claude -p`,
  Codex, etc. — as a replaceable subprocess (ADR-0001, ADR-0003).

  kazi is the outer loop; it never replaces the harness, it conducts it
  (concept §3). The harness boundary is deliberately thin: a subprocess invoked
  with a focused prompt seeded with **failing-predicate evidence**, run *in the
  target workspace* so the agent's edits land in place, with the result, diff,
  and cost captured (ADR-0001 consequences, concept §5). Because the boundary is
  a subprocess + structured I/O, it is language- and vendor-neutral — a better
  Claude Code makes kazi better for free (ADR-0001).

  This module is a **behaviour only** — `@callback` specs, no concrete
  implementation (zero-stub policy). The Slice 0 implementation is the `claude
  -p` adapter (T0.6), whose tests use a stub binary; later harnesses are new
  adapters, not core changes.

  ## Implementing

      defmodule MyApp.ClaudeAdapter do
        @behaviour Kazi.HarnessAdapter

        @impl true
        def run(prompt, workspace, opts) do
          # ... System.cmd("claude", ["-p", prompt], cd: workspace) ...
          {:ok, %{output: "...", cost: %{tokens: 1234}}}
        end
      end
  """

  @typedoc """
  The focused prompt handed to the harness — the work item plus the
  failing-predicate evidence that seeds the agent's context (concept §5).
  """
  @type prompt :: String.t()

  @typedoc "Path to the target workspace the harness runs in, so edits land in place."
  @type workspace :: String.t()

  @typedoc """
  Adapter options (e.g. model, timeout, budget hints, extra harness flags). A
  keyword list so adapters can accept harness-specific options without changing
  the contract.
  """
  @type opts :: keyword()

  @typedoc """
  The captured result of one harness invocation. On success, `result` carries
  what the loop records and reasons about: the harness output, the produced diff
  (if any), and the cost (tokens / wall-clock) — the inputs to budget and
  progress tracking (ADR-0001 consequences). `{:error, reason}` when the harness
  could not be run.
  """
  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Runs the harness with `prompt` in `workspace`, returning the captured result.

  The adapter must run the agent in `workspace` (not a copy) so edits land where
  the predicates are evaluated, and must capture enough in the result map for the
  loop to record evidence and account for cost.
  """
  @callback run(prompt :: prompt(), workspace :: workspace(), opts :: opts()) :: result()
end
