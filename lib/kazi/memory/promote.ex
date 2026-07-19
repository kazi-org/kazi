defmodule Kazi.Memory.Promote do
  @moduledoc """
  ADR-0063 decision 3: writes an APPROVED `Kazi.ReadModel.ProposedMemory` into
  its routed corpus file as an ordinary working-tree edit -- kazi never
  commits memory on its own authority; the operator reviews and lands the
  diff exactly like any other doc change (ADR-0034). `kazi memory approve
  <ref>` calls this the moment it transitions a proposal to `approved`.

  ## Routing (the ADR-0036 tier map)

  `target_doc/1` is the SAME class -> file map `.github/scripts/
  extract_knowledge.py` uses for archived-plan knowledge extraction:
  invariant/landmine -> `docs/lore.md`, finding/benchmark -> `docs/devlog.md`,
  decision -> a drafted `docs/adr/` stub. It is computed once, at proposal
  time (`Kazi.Memory.Harvest` calls it when building a candidate), and stored
  on the row's `target_doc` field so promotion never re-derives routing from
  a class that could theoretically change underneath it.

  ## Provenance + idempotency

  Every written entry carries a `<!-- kx:<fingerprint> -->` trailer -- the
  SAME provenance-marker convention `extract_knowledge.py` uses. Promoting the
  same proposal twice is a no-op: the target file is checked for the marker
  first, so a re-run (or a second `approve` on an already-promoted proposal)
  never appends a duplicate entry.
  """

  alias Kazi.ReadModel.ProposedMemory

  @lore_path "docs/lore.md"
  @devlog_path "docs/devlog.md"
  @adr_dir "docs/adr"

  @doc """
  The corpus file (or directory, for `decision`) a memory `class` routes to.
  """
  @spec target_doc(String.t()) :: String.t()
  def target_doc(class) when class in ~w(invariant landmine), do: @lore_path
  def target_doc(class) when class in ~w(finding benchmark), do: @devlog_path
  def target_doc("decision"), do: @adr_dir
  def target_doc("architecture"), do: "docs/concept.md"
  def target_doc(_other), do: @devlog_path

  @doc """
  Writes `proposal`'s content into its routed corpus file under `workspace`
  (default the current directory), appending a `kx:<fingerprint>` provenance
  trailer. A no-op (returns the existing path) when the marker is already
  present -- promotion is idempotent.

  Returns `{:ok, path}` on success (including the no-op case) or
  `{:error, reason}` if the target file cannot be read/written.
  """
  @spec promote(ProposedMemory.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def promote(%ProposedMemory{target_doc: @adr_dir} = proposal, workspace) do
    marker = "kx:#{proposal.fingerprint}"
    dir = Path.join(workspace, @adr_dir)

    if adr_already_present?(dir, marker) do
      {:ok, dir}
    else
      write_adr_stub(dir, proposal, marker)
    end
  end

  def promote(%ProposedMemory{} = proposal, workspace) do
    path = Path.join(workspace, proposal.target_doc)
    marker = "kx:#{proposal.fingerprint}"

    with {:ok, existing} <- read_or_new(path) do
      if String.contains?(existing, marker) do
        {:ok, path}
      else
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, existing <> render_entry(proposal, marker))
        {:ok, path}
      end
    end
  end

  defp read_or_new(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_entry(%ProposedMemory{class: class, content: content}, marker) do
    today = Date.utc_today() |> Date.to_iso8601()

    "\n### ##{class} #{marker} -- harvested #{class}\n\n" <>
      "#{content}\n\n(harvested #{today} via `kazi memory approve`, ADR-0063.)\n"
  end

  defp adr_already_present?(dir, marker) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.any?(fn entry ->
          case File.read(Path.join(dir, entry)) do
            {:ok, text} -> String.contains?(text, marker)
            {:error, _} -> false
          end
        end)

      {:error, _} ->
        false
    end
  end

  defp write_adr_stub(dir, %ProposedMemory{} = proposal, marker) do
    File.mkdir_p!(dir)
    number = next_adr_number(dir)

    path =
      Path.join(dir, "#{String.pad_leading(to_string(number), 4, "0")}-harvested-decision.md")

    text =
      "# ADR #{String.pad_leading(to_string(number), 4, "0")}: harvested decision\n\n" <>
        "## Status\n\nProposed #{marker}\n\n" <>
        "## Date\n\n#{Date.utc_today() |> Date.to_iso8601()}\n\n" <>
        "## Context\n\nHarvested from goal #{proposal.goal_ref} (`kazi memory approve`, ADR-0063).\n\n" <>
        "#{proposal.content}\n"

    File.write!(path, text)
    {:ok, path}
  end

  defp next_adr_number(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Regex.run(~r/^(\d+)-/, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)
        |> case do
          [] -> 1
          numbers -> Enum.max(numbers) + 1
        end

      {:error, _} ->
        1
    end
  end
end
