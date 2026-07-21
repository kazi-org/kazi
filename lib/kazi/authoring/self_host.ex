defmodule Kazi.Authoring.SelfHost do
  @moduledoc """
  Self-hosting detection for the authoring surface (T45.10 exit-proof, #1668/#1669).

  kazi is SELF-HOSTING (`docs/self-hosting.md`): its own repo is a workspace `kazi
  plan`/`kazi apply` can target like any other, but it is ALSO the source of the
  engine that GRADES every goal's predicates. That collision produced two distinct
  authoring gaps the T45.10 dogfood hit in the SAME run, both invisible until then
  because no prior self-hosted goal happened to trip them:

    * **#1668** — a `cli`/`custom_script` predicate whose `cmd` names the SAME
      executable the workspace itself builds observes the INSTALLED/last-built
      binary, not the source tree a fix edits. Unsatisfiable by a source change
      alone until a release happens (proven live: `kazi help | grep -c "kazi
      dashboard"` stayed `0` against the installed v1.273.7 binary while `mix run
      -e 'Kazi.CLI.run(["help"])'` against the SAME edited tree already returned
      `1`). `own_binary_name/1` + `at_risk_predicates/2` detect it;
      `Kazi.Authoring.Clarify`'s `self-hosting-cli-predicate` floor question
      surfaces it — ADVISORY only, exactly like the existing
      `naked-grep-predicate`/`tree-clean-predicate` gaps, never blocking drafting.
    * **#1669** — with no `[enforcement] read_only_paths` (ADR-0042), a dispatched
      agent is free to edit the very provider file(s) that grade its own goal (and
      did, in the dogfood — a legitimate fix, but nothing distinguished it from
      one that was not, #1663). `default_read_only_paths/2` derives a MINIMAL
      read-only lease — only the provider file(s) THIS goal's own predicate kinds
      are graded by, never the whole engine — so kazi's routine self-improvement
      of an UNRELATED provider is not additionally flagged by a goal that merely
      happens to run against this repo.

  Both helpers degrade to `nil`/`[]` the instant `workspace` is not kazi's own
  source tree (no `lib/kazi/providers` directory there) — the overwhelmingly
  common case for `kazi plan`/`kazi apply` against an arbitrary target repo, and
  byte-identical to before this module existed.
  """

  alias Kazi.{Goal, Predicate}

  # =============================================================================
  # #1668 — a predicate that measures the installed binary, not the edited tree
  # =============================================================================

  @doc """
  The executable name `workspace`'s OWN `mix.exs` builds via its `escript` config
  (`"kazi"` for this repo), or `nil` when there is no `mix.exs` there, it declares
  no `escript`, or the file cannot be read.

  This is the one piece of I/O `at_risk_predicates/2` needs; kept separate so the
  detection itself stays pure (takes the resolved name as data) and is directly
  unit-testable without a real workspace on disk.
  """
  @spec own_binary_name(String.t()) :: String.t() | nil
  def own_binary_name(workspace) when is_binary(workspace) do
    case File.read(Path.join(workspace, "mix.exs")) do
      {:ok, contents} -> extract_escript_name(contents)
      {:error, _reason} -> nil
    end
  end

  @escript_block_regex ~r/defp\s+escript\s+do\s*(.*?)\n\s*end/s
  @escript_name_regex ~r/name:\s*"([^"]+)"/

  defp extract_escript_name(contents) do
    with [_, block] <- Regex.run(@escript_block_regex, contents),
         [_, name] <- Regex.run(@escript_name_regex, block) do
      name
    else
      _ -> nil
    end
  end

  @doc """
  Predicate ids in `goal` at self-hosting risk (#1668): a `:cli`/`:custom_script`
  predicate whose `cmd` equals `own_name` — i.e. it shells out to the SAME
  executable `own_name` names, which is unsatisfiable by a source edit alone (see
  the moduledoc). Pure — takes the name as plain data; see `own_binary_name/1` for
  the I/O that resolves it from a real workspace.

  Returns `[]` (the common case) when `own_name` is `nil` or no predicate's `cmd`
  matches it.
  """
  @spec at_risk_predicates(String.t() | nil, Goal.t()) :: [Predicate.id()]
  def at_risk_predicates(nil, _goal), do: []

  def at_risk_predicates(own_name, %Goal{} = goal) when is_binary(own_name) do
    goal
    |> Goal.all_predicates()
    |> Enum.filter(&self_hosting_cmd?(&1, own_name))
    |> Enum.map(& &1.id)
  end

  @self_hosting_kinds [:cli, :custom_script]

  defp self_hosting_cmd?(%Predicate{kind: kind, config: config}, own_name)
       when kind in @self_hosting_kinds do
    to_string(Map.get(config, :cmd, "")) == own_name
  end

  defp self_hosting_cmd?(_predicate, _own_name), do: false

  # =============================================================================
  # #1669 — no read-only lease on the code that grades this goal
  # =============================================================================

  # Provider file(s) implementing each predicate kind, workspace-relative,
  # mirroring `Kazi.Runtime`'s kind -> provider-module dispatch table. `:cli` and
  # `:custom_script` additionally grade through the SHARED `command_runner.ex`
  # seam — the exact file #1663 legitimately (but unflagged) edited in the T45.10
  # dogfood — so both carry it.
  @provider_files %{
    tests: ["lib/kazi/providers/test_runner.ex"],
    cli: ["lib/kazi/providers/cli.ex", "lib/kazi/providers/command_runner.ex"],
    custom_script: [
      "lib/kazi/providers/custom_script.ex",
      "lib/kazi/providers/command_runner.ex"
    ],
    ratchet: ["lib/kazi/providers/ratchet.ex"],
    static: ["lib/kazi/providers/static.ex"],
    mutation: ["lib/kazi/providers/mutation.ex"],
    property: ["lib/kazi/providers/property.ex"],
    cve: ["lib/kazi/providers/cve.ex"],
    coverage: ["lib/kazi/providers/coverage.ex"],
    http_probe: ["lib/kazi/providers/http_probe.ex"],
    prod_log: ["lib/kazi/providers/prod_log.ex"],
    browser: ["lib/kazi/providers/browser.ex"],
    landed: ["lib/kazi/providers/landed.ex"],
    scenario: ["lib/kazi/providers/scenario.ex"],
    docs_updated: ["lib/kazi/providers/docs_updated.ex"],
    no_stubs: ["lib/kazi/providers/no_stubs.ex"],
    oss_hygiene: ["lib/kazi/providers/oss_hygiene.ex"],
    render_proof: ["lib/kazi/providers/render_proof.ex"],
    spec_coverage: ["lib/kazi/providers/spec_coverage.ex"],
    gherkin: ["lib/kazi/providers/gherkin.ex"],
    visual_judge: ["lib/kazi/providers/visual_judge.ex"],
    metrics: ["lib/kazi/providers/metrics.ex"],
    plan_expanded: ["lib/kazi/providers/plan_expanded.ex"],
    swift_test: ["lib/kazi/providers/swift_test.ex"]
  }

  @doc """
  The MINIMAL `read_only_paths` (ADR-0042) to author for `goal` against
  `workspace` (#1669): the provider file(s) that grade THIS goal's own predicate
  kinds — never the whole engine — so a dispatched agent cannot edit the code
  that decides whether its own work passed, without also blocking kazi's routine
  self-improvement of an unrelated provider.

  Returns `[]` (no `[enforcement]` block needed beyond the runtime default —
  `Kazi.Enforcement.resolve/1`) when `workspace` is not kazi's own source tree (no
  `lib/kazi/providers` directory there, the common case) or the goal names no
  kind kazi ships a provider file for.
  """
  @spec default_read_only_paths(String.t(), Goal.t()) :: [String.t()]
  def default_read_only_paths(workspace, %Goal{} = goal) when is_binary(workspace) do
    if own_source_tree?(workspace) do
      goal
      |> Goal.all_predicates()
      |> Enum.flat_map(&Map.get(@provider_files, &1.kind, []))
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  # Whether `workspace` is (a checkout of) kazi's OWN source: the provider
  # implementation directory kazi's engine loads its providers from is actually
  # present there. The risk this guards is "does this workspace hold the grader
  # code", not "is it named kazi" — a vendored/embedded copy would correctly trip
  # this too.
  defp own_source_tree?(workspace) do
    workspace |> Path.join("lib/kazi/providers") |> File.dir?()
  end
end
