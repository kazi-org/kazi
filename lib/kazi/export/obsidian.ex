defmodule Kazi.Export.Obsidian do
  @moduledoc """
  Exports a goal's group taxonomy + predicate verdicts to an Obsidian VAULT
  (T12.6, ADR-0020 §Decision 5).

  A large goal organizes its predicates into a tree — pillar → domain →
  capability — via a declared `[[group]]` taxonomy (`Kazi.Goal.Group`,
  ADR-0020). This module renders that tree, and each group's `intended / built /
  pending` rollup (`Kazi.Goal.GroupTree`), into a directory of markdown notes an
  operator browses in Obsidian to read "where is the goal: what is intended,
  built, pending" per pillar (ADR-0020 §Context).

  ## What it writes

  A vault is one directory with:

    * **one note per GROUP** — its display name, verdict tag, its declared
      budget, the per-group rollup (intended / built / pending), `[[wikilinks]]`
      to its parent group and child groups, and a list of the predicates that
      belong directly to it (each `[[wikilinked]]`);
    * **one note per PREDICATE** — its provider kind, description, verdict tag,
      and a `[[wikilink]]` back up to its owning group;
    * an **OVERVIEW** note — the goal title, the whole per-group rollup table,
      and a MERMAID rollup diagram of the tree (each node labelled with its
      built/intended counts), so the structure reads at a glance.

  ## Verdict tags

  Each note carries an Obsidian tag reflecting its verdict, taken from the same
  `intended / built / pending` semantics as `Kazi.Goal.GroupTree`:

    * a PREDICATE is `#built` when its verdict is passing, else `#pending`
      (every predicate is intended, so a predicate tag distinguishes built from
      pending);
    * a GROUP is `#built` when every predicate in its scope is built
      (`pending == 0` and `intended > 0`), `#pending` when some remain, and
      `#intended` when its scope is empty (declared but carrying no predicates
      yet — pure intent).

  Without a live run a caller supplies no verdicts (or all-`false`), so every
  predicate reads `#pending` and the vault reflects the STATIC structure — the
  "intended, nothing built yet" reading. A caller that already holds verdicts
  (e.g. a `Kazi.PredicateVector`) can pass them to colour the vault with live
  state.

  ## Pure rendering + a thin I/O seam

  `render/2` is PURE: a goal + a verdict map deterministically yield a map of
  `relative-path => note-content`. The same goal and verdicts always produce the
  same vault, byte for byte (groups, predicates, and rollup rows are emitted in
  the goal's declared order). `write/3` is the only I/O: it `mkdir_p`s the target
  and writes each rendered note, so the vault content is unit-testable without
  touching disk, mirroring `Kazi.Authoring.RationaleAdr`'s pure-render /
  thin-write split.

  ## Backward compatibility

  A goal with no declared groups still renders: the OVERVIEW note is written
  (with an empty rollup and an empty diagram) and any ungrouped predicates get
  their own predicate notes tagged by verdict, so the exporter never crashes on a
  flat goal — it simply has no group notes to write.
  """

  alias Kazi.Goal
  alias Kazi.Goal.{Group, GroupTree}
  alias Kazi.Predicate

  @overview_note "OVERVIEW"

  @typedoc "A rendered vault: relative note path (with `.md`) → note content."
  @type vault :: %{optional(Path.t()) => String.t()}

  @doc """
  Renders `goal` into a vault — a map of `relative-path => note-content` — with
  per-group rollups computed from `verdicts` (predicate id → passing?).

  PURE and deterministic: the same goal + verdicts always yield the same map.
  An absent verdict counts as not-passing (pending), per `Kazi.Goal.GroupTree`,
  so a caller with no live run passes `%{}` and the vault reflects the static
  structure (every predicate pending).

  ## Examples

      iex> pillar = Kazi.Goal.Group.new("identity", "Identity")
      iex> goal = Kazi.Goal.new("g",
      ...>   name: "Demo",
      ...>   groups: [pillar],
      ...>   predicates: [Kazi.Predicate.new(:p1, :tests, group: "identity")])
      iex> vault = Kazi.Export.Obsidian.render(goal, %{p1: true})
      iex> Map.has_key?(vault, "OVERVIEW.md")
      true
      iex> vault["identity.md"] =~ "#built"
      true
  """
  @spec render(Goal.t(), GroupTree.verdicts()) :: vault()
  def render(%Goal{} = goal, verdicts \\ %{}) when is_map(verdicts) do
    rollup = GroupTree.rollup(goal, verdicts)
    tree = GroupTree.tree(goal)

    group_notes(goal, rollup, verdicts)
    |> Map.merge(predicate_notes(goal, verdicts))
    |> Map.put("#{@overview_note}.md", overview_note(goal, tree, rollup))
  end

  @doc """
  Renders `goal` with `verdicts` and writes the vault to `dir`.

  Creates `dir` (and parents) if absent, then writes each rendered note under it.
  Returns `{:ok, %{dir: dir, notes: [path]}}` with the written note paths (sorted,
  for a deterministic report), or `{:error, reason}` if a directory/file write
  failed. This is the only I/O; the vault content is produced purely by
  `render/2`.

  Opts:

    * `:verdicts` — the predicate verdict map (default `%{}`, the static
      "all pending" reading without a live run).
  """
  @spec write(Goal.t(), Path.t(), keyword()) ::
          {:ok, %{dir: Path.t(), notes: [Path.t()]}} | {:error, term()}
  def write(%Goal{} = goal, dir, opts \\ []) when is_binary(dir) and is_list(opts) do
    verdicts = Keyword.get(opts, :verdicts, %{})
    vault = render(goal, verdicts)

    with :ok <- File.mkdir_p(dir),
         :ok <- write_notes(dir, vault) do
      notes = vault |> Map.keys() |> Enum.sort() |> Enum.map(&Path.join(dir, &1))
      {:ok, %{dir: dir, notes: notes}}
    end
  end

  # Write each rendered note; stop at the first failure with its reason.
  defp write_notes(dir, vault) do
    Enum.reduce_while(vault, :ok, fn {rel, content}, :ok ->
      case File.write(Path.join(dir, rel), content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # --- group notes -----------------------------------------------------------

  defp group_notes(%Goal{groups: groups} = goal, rollup, verdicts) do
    parents = Map.new(groups, &{&1.id, &1})
    children_by_parent = Enum.group_by(groups, & &1.parent)
    own_preds = own_predicates_by_group(goal)

    Map.new(groups, fn %Group{} = group ->
      counts = Map.get(rollup, group.id, zero_counts())
      children = Map.get(children_by_parent, group.id, [])
      preds = Map.get(own_preds, group.id, [])

      content =
        group_note(group, counts, Map.get(parents, group.parent), children, preds, verdicts)

      {"#{note_name(group.id)}.md", content}
    end)
  end

  defp group_note(%Group{} = group, counts, parent, children, preds, verdicts) do
    """
    # #{group.name}

    #{group_tag(counts)}

    - id: `#{group.id}`#{budget_line(group.budget)}
    - intended: #{counts.intended}
    - built: #{counts.built}
    - pending: #{counts.pending}

    ## Parent

    #{parent_link(parent)}

    ## Child groups

    #{child_links(children)}

    ## Predicates

    #{predicate_links(preds, verdicts)}
    """
  end

  defp budget_line(nil), do: ""
  defp budget_line(budget), do: "\n- budget: #{budget}"

  defp parent_link(nil), do: "(none — this is a root group)"
  defp parent_link(%Group{} = parent), do: "[[#{note_name(parent.id)}]] — #{parent.name}"

  defp child_links([]), do: "(none)"

  defp child_links(children) do
    Enum.map_join(children, "\n", fn %Group{} = child ->
      "- [[#{note_name(child.id)}]] — #{child.name}"
    end)
  end

  defp predicate_links([], _verdicts), do: "(none belong directly to this group)"

  defp predicate_links(preds, verdicts) do
    Enum.map_join(preds, "\n", fn %Predicate{} = predicate ->
      "- [[#{predicate_note_name(predicate)}]] (#{predicate_tag(predicate, verdicts)})"
    end)
  end

  # --- predicate notes -------------------------------------------------------

  defp predicate_notes(%Goal{} = goal, verdicts) do
    groups = Map.new(goal.groups, &{&1.id, &1})

    goal
    |> Goal.all_predicates()
    |> Map.new(fn %Predicate{} = predicate ->
      {"#{predicate_note_name(predicate)}.md",
       predicate_note(predicate, Map.get(groups, predicate.group), verdicts)}
    end)
  end

  defp predicate_note(%Predicate{} = predicate, group, verdicts) do
    """
    # #{predicate.id}

    #{predicate_tag(predicate, verdicts)}

    - id: `#{predicate.id}`
    - provider: `#{predicate.kind}`
    - verdict: #{verdict_word(predicate, verdicts)}#{predicate_description(predicate)}

    ## Group

    #{predicate_group_link(group)}
    """
  end

  defp predicate_description(%Predicate{description: d}) when is_binary(d) and d != "",
    do: "\n- description: #{d}"

  defp predicate_description(_predicate), do: ""

  defp predicate_group_link(nil), do: "(ungrouped)"
  defp predicate_group_link(%Group{} = group), do: "[[#{note_name(group.id)}]] — #{group.name}"

  # --- overview note + mermaid -----------------------------------------------

  defp overview_note(%Goal{} = goal, tree, rollup) do
    """
    # #{goal.name || goal.id}

    #intended

    Goal `#{goal.id}` — the declared group taxonomy and its per-group rollup
    (intended / built / pending), exported from kazi (ADR-0020).

    ## Per-group rollup

    #{rollup_table(goal, rollup)}

    ## Rollup diagram

    ```mermaid
    #{mermaid(tree, rollup)}
    ```

    ## Groups

    #{overview_group_links(goal)}
    """
  end

  # A markdown table of every declared group's rollup, in the goal's declared
  # order, so the table is deterministic and matches the tree's sibling order.
  defp rollup_table(%Goal{groups: []}, _rollup), do: "(no groups declared)"

  defp rollup_table(%Goal{groups: groups}, rollup) do
    header = "| group | intended | built | pending |\n| --- | --- | --- | --- |"

    rows =
      Enum.map_join(groups, "\n", fn %Group{} = group ->
        c = Map.get(rollup, group.id, zero_counts())
        "| [[#{note_name(group.id)}]] | #{c.intended} | #{c.built} | #{c.pending} |"
      end)

    header <> "\n" <> rows
  end

  defp overview_group_links(%Goal{groups: []}), do: "(none)"

  defp overview_group_links(%Goal{groups: groups}) do
    Enum.map_join(groups, "\n", fn %Group{} = group ->
      "- [[#{note_name(group.id)}]] — #{group.name}"
    end)
  end

  # A Mermaid flowchart of the tree: a node per group labelled with its name and
  # built/intended counts, and an edge from each parent to each child. Emitted by
  # walking the reconstructed tree, so the order is deterministic. An empty tree
  # yields a single comment line so the fenced block is still valid Mermaid.
  defp mermaid([], _rollup), do: "graph TD\n  %% no groups declared"

  defp mermaid(tree, rollup) do
    lines =
      tree
      |> Enum.flat_map(&mermaid_lines(&1, rollup))
      |> Enum.uniq()

    Enum.join(["graph TD" | lines], "\n  ")
  end

  defp mermaid_lines(%{group: %Group{} = group, children: children}, rollup) do
    node = mermaid_node(group, rollup)

    child_lines =
      Enum.flat_map(children, fn %{group: %Group{} = child} = child_node ->
        edge = "#{mermaid_id(group.id)} --> #{mermaid_id(child.id)}"
        [edge | mermaid_lines(child_node, rollup)]
      end)

    [node | child_lines]
  end

  # A node declaration `id["Name (built/intended)"]`. The label carries the
  # built/intended ratio so the diagram reads convergence at a glance.
  defp mermaid_node(%Group{} = group, rollup) do
    c = Map.get(rollup, group.id, zero_counts())
    "#{mermaid_id(group.id)}[\"#{escape_mermaid(group.name)} (#{c.built}/#{c.intended})\"]"
  end

  # A Mermaid-safe node id: the group slug with hyphens → underscores (Mermaid
  # ids must be alphanumeric/underscore), prefixed so a leading digit is legal.
  defp mermaid_id(group_id), do: "g_" <> String.replace(group_id, "-", "_")

  defp escape_mermaid(text), do: String.replace(text, "\"", "'")

  # --- verdict tagging -------------------------------------------------------

  # A predicate is built iff its verdict is passing; an absent verdict (never
  # observed) reads as pending — the same rule as `Kazi.Goal.GroupTree`.
  defp built?(%Predicate{id: id}, verdicts), do: Map.get(verdicts, id, false) == true

  defp predicate_tag(%Predicate{} = predicate, verdicts) do
    if built?(predicate, verdicts), do: "#built", else: "#pending"
  end

  defp verdict_word(%Predicate{} = predicate, verdicts) do
    if built?(predicate, verdicts), do: "built", else: "pending"
  end

  # A group's tag from its scope rollup: built when every predicate in scope
  # passes, pending when some remain, intended when the scope is empty (declared
  # but carrying no predicates yet — pure intent).
  defp group_tag(%{intended: 0}), do: "#intended"
  defp group_tag(%{pending: 0}), do: "#built"
  defp group_tag(_counts), do: "#pending"

  # --- shared helpers --------------------------------------------------------

  defp own_predicates_by_group(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> Enum.filter(& &1.group)
    |> Enum.group_by(& &1.group)
  end

  # A predicate's note name, namespaced so a predicate id can never collide with
  # a group's note (group notes use the bare slug).
  defp predicate_note_name(%Predicate{id: id}), do: "predicate-" <> note_name(id)

  # A note's file name: the id, with filesystem/Obsidian-hostile characters
  # collapsed to hyphens so a `[[wikilink]]` resolves to exactly this file.
  defp note_name(id) do
    id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/u, "-")
    |> String.trim("-")
  end

  defp zero_counts, do: %{intended: 0, built: 0, pending: 0}
end
