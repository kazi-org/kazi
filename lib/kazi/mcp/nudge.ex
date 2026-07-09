defmodule Kazi.MCP.Nudge do
  @moduledoc """
  A one-time, prose-only nudge toward `kazi init --with-mcp` (issue #972).

  Every `kazi apply` falls back to the JSON-CLI shell-out path when the calling
  project's `.mcp.json` has no `kazi` server entry -- silently, by omission, not
  by choice. `maybe_print/1` surfaces that once per project, after a serial
  `apply`'s human (non `--json`) report: `--json` output must stay pure
  (ADR-0023/issue #804), so this is never called on that surface.

  "Once per project" is tracked with a marker file under the workspace's own
  `.kazi/` dir (the same project-local state directory `Kazi.Ratchet.Store`
  uses), so the nudge survives across separate `kazi` invocations but is scoped
  to the project, not the machine.
  """

  alias Kazi.MCP.ClientConfig

  @marker_filename "mcp_nudge_shown"

  @doc """
  Prints the nudge line once for `workspace`, then never again: no-op when the
  marker is already recorded, and no-op (without recording) when `.mcp.json`
  already declares the `kazi` MCP entry.
  """
  @spec maybe_print(String.t()) :: :ok
  def maybe_print(workspace) when is_binary(workspace) do
    marker = marker_path(workspace)

    if File.exists?(marker) or ClientConfig.configured_in_dir?(workspace) do
      :ok
    else
      IO.puts(
        "\nMCP not configured for this project -- run `kazi init --with-mcp` to expose " <>
          "kazi as a typed MCP tool instead of the JSON-CLI shell-out " <>
          "(docs: docs/orchestrator-recipe.md, section 5)."
      )

      record_shown(marker)
    end
  end

  defp marker_path(workspace), do: Path.join([workspace, ".kazi", @marker_filename])

  defp record_shown(marker) do
    with :ok <- File.mkdir_p(Path.dirname(marker)) do
      File.write(marker, "")
    end

    :ok
  end
end
