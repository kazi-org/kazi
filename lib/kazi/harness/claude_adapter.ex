defmodule Kazi.Harness.ClaudeAdapter do
  @moduledoc """
  The original `Kazi.HarnessAdapter` implementation for `claude -p`, now a **thin
  back-compat shim** over the generic adapter (T8.3, ADR-0016).

  Claude is no longer special-cased: `run/3` delegates to
  `Kazi.Harness.CliAdapter.run/3` with the `:claude` harness selected, so the
  driving path (argv assembly, `System.cmd` in the workspace, JSON-envelope
  parsing) is the SAME generic path every other harness flows through. The
  Claude-specific boundary logic lives in the `:claude` profile
  (`Kazi.Harness.Profiles.Claude`); the byte-for-byte equivalence with the old
  bespoke adapter is pinned by the golden test in `profile_registry_test.exs`.

  The harness-neutral prompt construction (`build_prompt/2,3`,
  `render_retrieval_section/1`, `truncate_evidence/2`) moved to the vendor-neutral
  `Kazi.Harness.Prompt`; this module re-exports those functions via
  `defdelegate` so existing callers and tests that reach them through
  `ClaudeAdapter` keep working unchanged. New code should call
  `Kazi.Harness.Prompt` (prompt construction) and `Kazi.Harness.CliAdapter`
  (dispatch) directly.

  ## Result map

  Identical to `Kazi.Harness.CliAdapter` (it IS that adapter): the always-present
  base map —

      %{output: binary(), exit: integer(), command: binary(), workspace: binary()}

  — merged with whatever the `:claude` profile's parser extracted from the JSON
  envelope (`:result`, `:tokens`, `:cost_usd`, `:touched`, `:cost => %{tokens: n}`),
  additively. Errors are the generic adapter's:

      {:error, :empty_prompt}
      {:error, {:command_not_found, binary()}}
  """

  @behaviour Kazi.HarnessAdapter

  alias Kazi.Harness.CliAdapter
  alias Kazi.Harness.Prompt

  # Legacy command resolution this shim preserves for back-compat: the bespoke
  # adapter resolved the binary as `opts[:command]` > `config :kazi,
  # :harness_command` > `"claude"`. The generic adapter only reads `opts[:command]`
  # and the profile default, so the shim threads the config fallback through as an
  # explicit `:command` to keep every existing caller and test unaffected.
  @default_command "claude"

  @impl true
  def run(prompt, workspace, opts)
      when is_binary(prompt) and is_binary(workspace) and is_list(opts) do
    # Drive Claude through the generic adapter, defaulting the harness to `:claude`
    # so a caller that passed no `:harness` (every existing one) gets exactly the
    # old Claude behaviour — byte-identical, per the T8.2 golden test. The legacy
    # `:harness_command` config fallback is honoured before handing off.
    opts =
      opts
      |> Keyword.put_new(:harness, :claude)
      |> Keyword.put_new_lazy(:command, &legacy_command/0)

    CliAdapter.run(prompt, workspace, opts)
  end

  # Resolve the legacy app-config command, falling back to the historical
  # `"claude"` default. Only consulted when the caller passed no `:command`.
  defp legacy_command do
    Application.get_env(:kazi, :harness_command, @default_command)
  end

  # Harness-neutral prompt construction now lives in `Kazi.Harness.Prompt`; these
  # delegations preserve the `ClaudeAdapter.*` call sites (existing tests and
  # callers) without duplicating any logic.
  defdelegate build_prompt(work_item, failing), to: Prompt
  defdelegate build_prompt(work_item, failing, opts), to: Prompt
  defdelegate render_retrieval_section(snippets), to: Prompt
  defdelegate truncate_evidence(evidence, opts \\ []), to: Prompt
end
