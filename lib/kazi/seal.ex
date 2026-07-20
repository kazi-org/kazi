defmodule Kazi.Seal do
  @moduledoc """
  Sealed predicates — cryptographic tamper detection on the acceptance contract
  (ADR-0080, #1520).

  A converging worker has both motive and write access to the files that define
  its own acceptance bar: the goal-file, and any auxiliary inputs its predicates
  consume (pixel-check manifests, reference images, checker scripts, fixtures).
  ADR-0042 `read_only_paths` only FLAGS a write to those (advisory, the run
  continues); sealing makes tampering **fatal**.

  This module is two things:

    1. The authored `[seal]` config struct (`enabled`, `sealed_inputs`,
       `mutable_inputs`), parsed from the goal-file and carried on `Kazi.Goal`.
    2. `arm/3` + `verify/1`: `arm/3` content-hashes the sealed set once at run
       start into a manifest; `verify/1` re-hashes and returns the first
       mismatch. The loop arms at t0 and verifies before every observe pass; a
       mismatch terminates the run `:tampered` naming the offending file.

  Pure w.r.t. the loop: `arm/3` reads the filesystem once, `verify/1` reads it
  each call; neither couples to `Kazi.Loop.Data`. Hashing mirrors the ADR-0042
  `Kazi.Enforcement` primitive (SHA-256 of bytes; a directory hashes its sorted
  file tree; a missing path is `:absent`).

  ## The manifest

  A `manifest` is `%{label => {absolute_path, digest}}`:

    * `label` — the human-facing path in the tamper diagnostic (the
      workspace-relative path for a sealed input; the goal-file source path for
      the implicit goal-file entry).
    * `absolute_path` — where `verify/1` re-reads the file.
    * `digest` — SHA-256 of the bytes at t0, or `:absent`.

  An empty manifest (`%{}`) means "nothing sealed" and `verify/1` is a no-op —
  the state a `Loop.start_link` with no seal, a goal with NO `[seal]` block, or a
  `[seal] enabled = false` goal produces (byte-identical to pre-ADR-0080 behavior).

  ## Sealing is opt-in per goal-file

  A goal that declares no `[seal]` block seals NOTHING — not even its own
  goal-file. This keeps the goal-drift guard (#1415) intact: goal-drift
  deliberately tolerates a goal-file rewritten mid-run (the original t0 bar still
  governs convergence, and the drift is reported observationally via
  `goal_drifted`, never fatally). Sealing the goal-file unconditionally would
  terminate every such run `:tampered` before goal-drift could surface anything,
  silently replacing that shipped contract. Declaring `[seal]` is the explicit
  opt-in: from then on the goal-file AND the declared `sealed_inputs` are
  tamper-fatal, which is the #1520 incident class (a worker loosening the pixel
  manifest that grades it).
  """

  @type change :: :modified | :removed | :added
  @type digest :: binary() | :absent
  @type manifest :: %{optional(String.t()) => {String.t(), digest()}}

  @type t :: %__MODULE__{
          enabled: boolean(),
          sealed_inputs: [String.t()],
          mutable_inputs: [String.t()]
        }

  defstruct enabled: true, sealed_inputs: [], mutable_inputs: []

  @doc """
  Arms the seal for a run: content-hashes the goal-file and every sealed input
  into a manifest.

    * `seal` — the goal's authored `%Kazi.Seal{}` config, or `nil` when the
      goal-file declared no `[seal]` block. `nil` seals NOTHING: sealing is
      opt-in per goal-file, so a goal that declares no `[seal]` behaves exactly
      as it did before ADR-0080 (and the #1415 goal-drift guard keeps its
      observational contract). Declaring `[seal]` opts the goal in, and then the
      goal-file itself is sealed alongside the declared inputs.
    * `goal_source` — the goal-file's on-disk path, or `nil` when the goal was
      built in memory / from a proposal (then the goal-file is not sealable and
      only `sealed_inputs` are).
    * `workspace` — the run's workspace, against which `sealed_inputs` (and their
      globs) resolve; `nil` seals nothing relative to a workspace.

  Returns the `manifest`. `enabled = false` fully opts out and returns `%{}`
  (nothing sealed, including the goal-file).

  ## Examples

      iex> Kazi.Seal.arm(%Kazi.Seal{enabled: false, sealed_inputs: ["a"]}, "g.toml", "/ws")
      %{}
  """
  @spec arm(t() | nil, String.t() | nil, String.t() | nil) :: manifest()
  def arm(%__MODULE__{enabled: false}, _goal_source, _workspace), do: %{}

  # No `[seal]` block ⇒ sealing is OFF for this goal, including the goal-file.
  # Sealing is opt-in per goal-file (declaring `[seal]` opts in), which keeps the
  # goal-drift guard (#1415) intact: goal-drift deliberately TOLERATES a goal-file
  # rewritten mid-run — the original t0 bar governs convergence and the drift is
  # reported observationally (`goal_drifted`), never fatally. An unconditional
  # implicit goal-file seal would terminate every such run `:tampered` before
  # goal-drift could surface anything, silently replacing a shipped contract. An
  # author who wants the goal-file itself to be tamper-fatal declares `[seal]`.
  def arm(nil, _goal_source, _workspace), do: %{}

  def arm(seal, goal_source, workspace) do
    goal_entry(goal_source)
    |> Map.merge(input_entries(seal, workspace))
  end

  @doc """
  Re-verifies a manifest against the current filesystem. Returns `:ok` when every
  sealed path still hashes to its t0 digest, or `{:tampered, %{path:, change:}}`
  for the FIRST path whose content changed (sorted by label for a deterministic
  verdict). `change` is `:removed` (was present, now absent), `:added` (was
  absent at t0, now present), or `:modified` (bytes differ).

  An empty manifest is always `:ok`.
  """
  @spec verify(manifest()) :: :ok | {:tampered, %{path: String.t(), change: change()}}
  def verify(manifest) when manifest == %{}, do: :ok

  def verify(manifest) do
    manifest
    |> Enum.sort_by(fn {label, _entry} -> label end)
    |> Enum.find_value(:ok, fn {label, {abs_path, sealed_digest}} ->
      case classify(sealed_digest, hash(abs_path)) do
        nil -> nil
        change -> {:tampered, %{path: label, change: change}}
      end
    end)
  end

  @doc """
  Builds a `%Kazi.Seal{}` from a keyword/opts shape (the loader's parsed block).
  `nil`/absent yields `nil` (no `[seal]` block — only the goal-file is sealed).
  """
  @spec new(keyword() | nil) :: t() | nil
  def new(nil), do: nil

  def new(opts) when is_list(opts) do
    %__MODULE__{
      enabled: Keyword.get(opts, :enabled, true),
      sealed_inputs: Keyword.get(opts, :sealed_inputs, []),
      mutable_inputs: Keyword.get(opts, :mutable_inputs, [])
    }
  end

  # The implicit goal-file seal: always sealed when we know its path (ADR-0080 §1).
  defp goal_entry(nil), do: %{}

  defp goal_entry(goal_source) when is_binary(goal_source),
    do: %{goal_source => {goal_source, hash(goal_source)}}

  # The declared sealed_inputs, glob-expanded under the workspace, minus
  # mutable_inputs (the subtractive opt-out, ADR-0080 §4).
  defp input_entries(nil, _workspace), do: %{}
  defp input_entries(_seal, nil), do: %{}

  defp input_entries(%__MODULE__{sealed_inputs: inputs, mutable_inputs: mutable}, workspace) do
    mutable_set = expand(mutable, workspace) |> MapSet.new()

    inputs
    |> expand(workspace)
    |> Enum.reject(&MapSet.member?(mutable_set, &1))
    |> Map.new(fn rel -> {rel, {Path.join(workspace, rel), hash(Path.join(workspace, rel))}} end)
  end

  # Expand a list of repo-relative paths (globs allowed) to concrete
  # workspace-relative file paths. A literal path that matches nothing is kept as
  # itself, so an absent sealed input is still sealed (and reads :absent at t0,
  # so a later appearance is an :added tamper).
  defp expand(paths, workspace) do
    paths
    |> Enum.flat_map(fn rel ->
      case Path.wildcard(Path.join(workspace, rel)) do
        [] -> [rel]
        matches -> Enum.map(matches, &Path.relative_to(&1, workspace))
      end
    end)
    |> Enum.uniq()
  end

  # nil digest transitions ⇒ the kind of tamper, or nil for "unchanged".
  defp classify(same, same), do: nil
  defp classify(:absent, _now), do: :added
  defp classify(_t0, :absent), do: :removed
  defp classify(_t0, _now), do: :modified

  # SHA-256 of a path's content: a file by its bytes, a directory by its sorted
  # {relative-path, file-hash} tree, an absent path to :absent. Mirrors
  # Kazi.Enforcement's hashing so seal and enforcement agree on what "changed".
  @spec hash(String.t()) :: digest()
  defp hash(path) do
    cond do
      File.regular?(path) -> file_hash(path)
      File.dir?(path) -> dir_hash(path)
      true -> :absent
    end
  end

  defp file_hash(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, _} -> :absent
    end
  end

  defp dir_hash(path) do
    entries =
      path
      |> list_files_recursive()
      |> Enum.sort()
      |> Enum.map(fn file -> {Path.relative_to(file, path), file_hash(file)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(entries))
  end

  defp list_files_recursive(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)
      if File.dir?(full), do: list_files_recursive(full), else: [full]
    end)
  rescue
    _ -> []
  end

  @doc false
  # Exposed for the loader / a `--check` / `--explain` surface: the labels this
  # config would seal (goal-file entry excluded — the caller adds it), so an
  # author can verify their seal coverage.
  @spec sealed_labels(t() | nil, String.t() | nil) :: [String.t()]
  def sealed_labels(nil, _workspace), do: []
  def sealed_labels(%__MODULE__{enabled: false}, _workspace), do: []

  def sealed_labels(%__MODULE__{} = seal, workspace),
    do: seal |> input_entries(workspace) |> Map.keys() |> Enum.sort()
end
