defmodule Kazi.Plan.Render do
  @moduledoc """
  Renders a goal's per-scope-root **node** — the content `AGENTS.md`/`CLAUDE.md`
  carries at a goal's scope root so a harness's own directory walk-up delivers
  the goal's acceptance contract to an agent working there (ADR-0086 decision 3,
  T72.3).

  ## Why `node/3` takes DATA, never a repo handle

  A render that reached into `Kazi.ReadModel.RunRegistry.list/0`-shaped
  read-model access, or the read-model's Ecto repo (`Kazi.Repo`), would put a
  live host dependency in the render path — a containerized fleet lane's
  canary image, or a fresh clone with no running `kazi` daemon, could then
  never reproduce the node byte-for-byte (ADR-0086 context: "the canary image
  carries no kazi binary, so nothing can be rendered inside a container at
  dispatch time"). Keeping `node/3` a function of `(goal, root, observed)`
  alone means ANY host that has the goal-file and the kazi binary re-derives
  the identical node — the freshness check ADR-0086 decision 5 describes
  (re-render, byte-compare) is only meaningful if the render itself cannot see
  anything the byte-comparison doesn't also see.

  `test/kazi/plan/render_test.exs`'s "purity" describe pins this BY
  CONSTRUCTION, the same way `test/kazi/scenario/pin_test.exs` pins
  `Kazi.Scenario.Pin`'s I/O-freedom: it inspects this module's COMPILED
  `:imports` chunk (`:beam_lib.chunks/2`) for `Kazi.ReadModel.RunRegistry` and
  `Kazi.Repo`, so a future edit that reaches for either fails the test at
  compile-time reality, not by convention.

  ## What the node contains

  Per ADR-0086 decision 3, `node/3` renders, in order:

    * the SAME "GENERATED — DO NOT HAND-EDIT" banner `kazi plan render`
      already uses for the roadmap view (ADR-0082) — reused verbatim via
      `Kazi.Goal.Roadmap.Render.banner/0`, not reinvented here, so decision 6's
      "does this file carry the generated banner" check has exactly one banner
      to look for;
    * the goal's id, name, declared scope root, and brief (`description`);
    * every VISIBLE predicate's definition (id, provider, what it checks) —
      "visible" excludes `held_out?` predicates (ADR-0042 §6): a node walked up
      into by an agent's harness is exactly the dispatch-context channel that
      hidden-for-acceptance withholding already protects (`Kazi.Loop`'s
      `held_out_ids/1` filtering), so this module applies the SAME exclusion
      independently rather than assume a caller already filtered; and
    * the CURRENTLY FAILING predicates (status `:fail` in `observed`, again
      excluding held-out ones), each with its evidence rendered the same
      sorted-map-then-redacted shape `Kazi.Harness.Prompt` uses for the dispatch
      prompt, so the two evidence-facing surfaces read identically.

  ## Byte-stability

  `node/3` is pure and total. The only unordered input is `observed`'s
  `PredicateVector.results` map and each result's `evidence` map; both are
  read only through deterministic paths (`PredicateVector.failing/1`'s result
  feeds a `MapSet` membership test, never an iteration order; evidence keys
  are sorted before rendering) so identical `(goal, root, observed)` triples
  render byte-identical strings regardless of map insertion order —
  `test/kazi/plan/render_test.exs`'s repeat/shuffle test pins this.

  This module does NOT write anything to disk, does not know about
  `--tree`, worktrees, or `AGENTS.md`/`CLAUDE.md` file paths — that delivery
  adapter is T72.4 (ADR-0086 decision 4). This is only the pure render.
  """

  alias Kazi.Goal
  alias Kazi.Goal.Roadmap.Render, as: RoadmapRender
  alias Kazi.Predicate
  alias Kazi.PredicateResult
  alias Kazi.PredicateVector

  @doc """
  Renders `goal`'s node for the scope root `root`, seeded with `observed` (the
  latest `Kazi.PredicateVector` for `goal`).

  Pure and total: no file I/O, no read-model access. `root` is rendered
  verbatim (it is caller-supplied context — T72.4 resolves it from
  `Kazi.Scope.roots/1` — not re-derived here, so this module carries no
  opinion about which of a goal's several roots a given node is for).

  ## Examples

      iex> goal = Kazi.Goal.new("g", predicates: [Kazi.Predicate.new(:unit, :tests, description: "unit suite passes")])
      iex> observed = Kazi.PredicateVector.new(%{unit: Kazi.PredicateResult.fail(%{output: "boom"})})
      iex> node = Kazi.Plan.Render.node(goal, "lib/g", observed)
      iex> node =~ "GENERATED" and node =~ "lib/g" and node =~ "unit" and node =~ "boom"
      true
  """
  @spec node(Goal.t(), String.t(), PredicateVector.t()) :: String.t()
  def node(%Goal{} = goal, root, %PredicateVector{} = observed) when is_binary(root) do
    [
      RoadmapRender.banner(),
      header(goal, root),
      predicate_definitions(goal),
      failing_section(goal, observed)
    ]
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  # --- sections ---

  defp header(%Goal{id: id} = goal, root) do
    [
      "# Goal: #{id}#{name_suffix(goal)}",
      "",
      "**Scope root:** `#{root}`",
      "",
      brief(goal),
      ""
    ]
    |> Enum.join("\n")
  end

  defp name_suffix(%Goal{name: name}) when is_binary(name) and name != "", do: " — #{name}"
  defp name_suffix(_goal), do: ""

  defp brief(%Goal{description: description}) when is_binary(description) and description != "",
    do: description

  defp brief(_goal), do: "_(no brief declared)_"

  defp predicate_definitions(%Goal{} = goal) do
    header = "## Predicates\n"

    case visible_predicates(goal) do
      [] ->
        header <> "\n_No predicates declared._\n"

      predicates ->
        header <> "\n" <> Enum.map_join(predicates, "\n", &render_definition/1) <> "\n"
    end
  end

  defp render_definition(%Predicate{id: id, kind: kind, description: description} = predicate) do
    "- `#{id}`#{guard_tag(predicate)} — provider `#{kind}`: #{description_or_placeholder(description)}"
  end

  defp guard_tag(predicate) do
    if Predicate.guard?(predicate), do: " (guard)", else: ""
  end

  defp description_or_placeholder(description) when is_binary(description) and description != "",
    do: description

  defp description_or_placeholder(_description), do: "(no description)"

  defp failing_section(%Goal{} = goal, %PredicateVector{} = observed) do
    header = "## Currently failing\n"
    failing_ids = observed |> PredicateVector.failing() |> MapSet.new()

    goal
    |> visible_predicates()
    |> Enum.filter(&MapSet.member?(failing_ids, &1.id))
    |> case do
      [] ->
        header <> "\n_No predicates are currently failing._\n"

      predicates ->
        header <>
          "\n" <> Enum.map_join(predicates, "\n", &render_failing(&1, observed))
    end
  end

  defp render_failing(%Predicate{id: id, kind: kind, description: description}, observed) do
    result = PredicateVector.get(observed, id)

    [
      "### `#{id}` — provider `#{kind}`",
      description_or_placeholder(description),
      "",
      "Evidence:",
      render_evidence(result)
    ]
    |> Enum.join("\n")
  end

  # The predicates a node ever shows: the goal's ordinary predicates AND its
  # guards (`Goal.all_predicates/1`), minus any `held_out?` predicate
  # (ADR-0042 §6). Applied to BOTH the definitions section and the failing
  # section so a held-out predicate never surfaces its id, description, or
  # evidence in a node the walk-up hands an agent.
  @spec visible_predicates(Goal.t()) :: [Predicate.t()]
  defp visible_predicates(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> Enum.reject(&Predicate.held_out?/1)
  end

  defp render_evidence(nil), do: "_(not yet observed)_"

  defp render_evidence(%PredicateResult{evidence: evidence}) when map_size(evidence) == 0,
    do: "_(no evidence captured)_"

  defp render_evidence(%PredicateResult{evidence: evidence}) do
    evidence
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> "- #{key}: #{stringify(value)}" end)
  end

  # Evidence leaves the workspace into a file a harness reads on every dispatch
  # in the scope root — the SAME egress `Kazi.Harness.Prompt` redacts before it
  # reaches a third-party agent prompt (T35.3, ADR-0009 amendment). Route
  # through the SAME redactor so both egress paths redact identically.
  defp stringify(value) when is_binary(value), do: Kazi.Redaction.redact(value)
  defp stringify(value), do: Kazi.Redaction.redact(inspect(value))

  defp ensure_trailing_newline(string) do
    if String.ends_with?(string, "\n"), do: string, else: string <> "\n"
  end
end
