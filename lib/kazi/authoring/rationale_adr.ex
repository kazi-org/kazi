defmodule Kazi.Authoring.RationaleAdr do
  @moduledoc """
  Writes an ADR-lite rationale document for a proposed goal (T11.7, UC-029,
  ADR-0019).

  `kazi propose --adr` opts into a written paper trail: alongside the inline
  rationale stored on the goal (T11.5), it renders the proposal -- the idea, the
  acceptance predicates, and the "why / what is out of scope" rationale -- into a
  numbered markdown file under `docs/adr/`, in the repo's ADR format. It is opt-in
  precisely so the default stays clean (ADR-0019).

  `write/2` is idempotent for a given proposal: it reuses the existing file that
  references the same `proposal_ref` rather than allocating a new number, so
  re-running `propose --adr` on the same idea overwrites in place instead of
  proliferating near-duplicate ADRs.
  """

  alias Kazi.Authoring.Draft
  alias Kazi.Goal

  @doc """
  Renders `draft` into an ADR-lite markdown file and writes it.

  Opts:

    * `:dir` -- the target directory (default `"docs/adr"`).
    * `:date` -- the date stamped in the doc (default `Date.utc_today/0`); injected
      in tests for determinism.

  Returns `{:ok, path}` with the written path, or `{:error, reason}` if the write
  failed. Idempotent: a file already referencing `draft.proposal_ref` is rewritten
  at its existing path; otherwise the next sequence number is allocated.
  """
  @spec write(Draft.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write(%Draft{} = draft, opts \\ []) do
    dir = Keyword.get(opts, :dir, "docs/adr")
    date = Keyword.get(opts, :date, Date.utc_today())

    with :ok <- File.mkdir_p(dir) do
      path = adr_path(dir, draft)
      number = leading_number(path) || 0

      case File.write(path, render(draft, date, number)) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The destination path: reuse an existing ADR that already references this
  # proposal_ref (idempotent re-run), otherwise allocate `NNNN-<slug>.md` at the
  # next free number.
  defp adr_path(dir, %Draft{} = draft) do
    case existing_for_ref(dir, draft.proposal_ref) do
      nil -> Path.join(dir, next_number(dir) <> "-" <> slug(draft.goal.id) <> ".md")
      path -> path
    end
  end

  defp existing_for_ref(dir, proposal_ref) do
    dir
    |> ls_md()
    |> Enum.find(fn path ->
      case File.read(path) do
        {:ok, content} -> String.contains?(content, proposal_ref)
        _ -> false
      end
    end)
  end

  # The next 4-digit sequence number = max existing leading number + 1.
  defp next_number(dir) do
    max =
      dir
      |> ls_md()
      |> Enum.map(&leading_number/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    (max + 1) |> Integer.to_string() |> String.pad_leading(4, "0")
  end

  defp ls_md(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  defp leading_number(path) do
    case Regex.run(~r/^(\d+)-/, Path.basename(path)) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  defp slug(goal_id) do
    goal_id
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "proposed-goal"
      s -> s
    end
  end

  # --- rendering -------------------------------------------------------------

  defp render(%Draft{} = draft, date, number) do
    title = draft.goal.name || draft.goal.id

    """
    # ADR #{number |> Integer.to_string() |> String.pad_leading(4, "0")}: Goal proposal -- #{title}

    ## Status
    Proposed

    ## Date
    #{Date.to_iso8601(date)}

    ## Context

    Authored from a prose idea via `kazi propose` (UC-029, ADR-0019). Idea:

    > #{draft.idea}

    proposal: `#{draft.proposal_ref}`

    ## Decision

    The goal is done when ALL of these machine-checkable acceptance predicates hold
    (ADR-0002):

    #{predicate_lines(draft.goal)}

    ## Consequences

    #{rationale(draft.goal)}
    """
  end

  defp predicate_lines(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> Enum.map_join("\n", fn predicate ->
      desc =
        case predicate.description do
          d when is_binary(d) and d != "" -> ": #{d}"
          _ -> ""
        end

      "- `#{predicate.id}` (#{predicate.kind})#{desc}"
    end)
  end

  defp rationale(%Goal{metadata: metadata}) do
    case Map.get(metadata, "rationale") do
      text when is_binary(text) and text != "" -> text
      _ -> "No rationale was recorded for this proposal."
    end
  end
end
