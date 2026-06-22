defmodule Kazi.Harness.ClaudeAdapter do
  @moduledoc """
  The Slice 0 `Kazi.HarnessAdapter` implementation: drive `claude -p` as a
  non-interactive subprocess *in the target workspace* so the agent's edits land
  in place (ADR-0001, ADR-0003; concept §5).

  This is the thin, vendor-neutral harness boundary made concrete: a subprocess
  invoked with a focused prompt seeded with failing-predicate evidence, run with
  `cd:` set to the workspace, capturing exit status and output as the result the
  loop records and reasons about.

  ## Harness-agnostic by configuration

  The command is configurable (R4 mitigation): pass `:command` in opts, set
  `config :kazi, :harness_command`, or fall back to the default `"claude"`. The
  same shape drives Codex or any other `-p`-style harness, and tests inject a
  stub binary the same way — there is nothing Claude-specific in the wiring.

  ## Result map

  On a successful invocation (the *process* ran; the agent may or may not have
  fixed anything — that is the predicates' job to judge later):

      {:ok, %{output: binary(), exit: integer(), command: binary(), workspace: binary()}}

  When the harness could not be run at all (e.g. the binary is missing):

      {:error, {:command_not_found, binary()}}
      {:error, :empty_prompt}
  """

  @behaviour Kazi.HarnessAdapter

  alias Kazi.PredicateResult

  @default_command "claude"

  @impl true
  def run("", _workspace, _opts), do: {:error, :empty_prompt}

  def run(prompt, workspace, opts)
      when is_binary(prompt) and is_binary(workspace) and is_list(opts) do
    command = command(opts)
    args = ["-p", prompt]

    try do
      {output, exit_status} =
        System.cmd(command, args,
          cd: workspace,
          stderr_to_stdout: true
        )

      {:ok,
       %{
         output: output,
         exit: exit_status,
         command: command,
         workspace: workspace
       }}
    rescue
      error in ErlangError ->
        # :enoent surfaces here when the configured binary is not on PATH —
        # an inability to run the harness, not failing work for the agent.
        case error.original do
          :enoent -> {:error, {:command_not_found, command}}
          other -> {:error, other}
        end
    end
  end

  @doc """
  Builds the focused prompt seeded with failing-predicate evidence (concept §5):
  the work item plus a concise, actionable rendering of what must become true.

  Pure and total so it can be tested directly. `failing` is a list of
  `{id, %Kazi.PredicateResult{}}` pairs — the failing slice of a
  `Kazi.PredicateVector` and their evidence — which the loop hands the adapter so
  the agent gets *only* the failing-predicate evidence as context (concept §86).

  ## Examples

      iex> failing = [{:unit, Kazi.PredicateResult.fail(%{output: "1 test, 1 failure"})}]
      iex> prompt = Kazi.Harness.ClaudeAdapter.build_prompt("Make the suite green", failing)
      iex> prompt =~ "Make the suite green" and prompt =~ "unit" and prompt =~ "1 failure"
      true
  """
  @spec build_prompt(String.t(), [{Kazi.Predicate.id(), PredicateResult.t()}]) :: String.t()
  def build_prompt(work_item, failing) when is_binary(work_item) and is_list(failing) do
    header =
      "#{work_item}\n\n" <>
        "The following predicates are currently failing. Make each one pass. " <>
        "Change the code under test, not the checks themselves.\n"

    body =
      failing
      |> Enum.map(&render_failing/1)
      |> Enum.join("\n")

    case body do
      "" -> String.trim_trailing(header)
      _ -> header <> "\n" <> body
    end
  end

  defp render_failing({id, %PredicateResult{status: status, evidence: evidence}}) do
    "## Failing predicate: #{id} (#{status})\n" <> render_evidence(evidence)
  end

  defp render_evidence(evidence) when map_size(evidence) == 0,
    do: "(no evidence captured)"

  defp render_evidence(evidence) do
    evidence
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> "- #{key}: #{stringify(value)}" end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  # Resolution order: explicit opt > app config > default. This is the seam that
  # makes the adapter harness-agnostic and lets tests inject a stub binary.
  defp command(opts) do
    Keyword.get(opts, :command) ||
      Application.get_env(:kazi, :harness_command, @default_command)
  end
end
