defmodule Kazi.Goal.GroupLint do
  @moduledoc """
  Fuzzy-compares a goal's declared group *display NAMES* and warns on
  near-duplicates (T12.7, ADR-0020 §Decision 3 — the **second net**).

  The loader (`Kazi.Goal.Loader`) is the FIRST net: it normalizes group `id`s to
  a canonical slug and rejects a DUPLICATE id at load time, so `"Identity &
  Access"` and `"identity-access"` cannot fragment the tree on their ids. But two
  groups can carry *distinct ids* and still have near-identical human NAMES —
  `"Identity & Access"` vs `"Identity and Access"`, `"Sign up"` vs `"Sign-up"` —
  which reads as an accidental fork to a human even though the loader accepted
  both. This module is the advisory second net ADR-0020 names: it fuzzy-compares
  the DECLARED NAMES (not the ids) and reports near-duplicates so the author can
  reconcile them.

  It is ADVISORY ONLY — it returns warnings, it never fails the load. A goal that
  loads is still a valid goal; a name near-duplicate is a smell to review, not an
  error (the id-uniqueness guard already prevents structural fragmentation).

  ## The fuzzy metric

  Each name is NORMALIZED first (`normalize_name/1`): lower-cased, the `&`/`and`
  conjunction dropped, and any run of non-alphanumeric characters collapsed to a
  single space — the same drift the id normalizer collapses, applied to the
  free-text name. Two names are then a near-duplicate when EITHER:

    * their normalized forms are EQUAL (e.g. `"Identity & Access"` vs `"Identity
      and Access"` both normalize to `"identity access"`) — a certain duplicate;
      OR
    * `String.jaro_distance/2` on the normalized forms is `>= threshold/0`
      (default `0.92`) — a near-duplicate by edit-distance similarity (a typo, a
      singular/plural, a transposition).

  The `0.92` threshold is deliberately HIGH: this is an advisory smell, so it
  favours precision (few false positives) over recall. `String.jaro_distance/2`
  is the stdlib metric (no new dependency, per the stack conventions). A pair is
  reported once (unordered), naming BOTH groups so the author can find them.

  Pure and total: a function of the goal's groups only — no I/O, no process
  state. The same goal always yields the same warnings.
  """

  alias Kazi.Goal
  alias Kazi.Goal.Group

  @typedoc """
  A near-duplicate-name warning. Names BOTH offending groups (their ids and the
  verbatim display names) and the fuzzy `similarity` score (`1.0` for a
  normalized-equal pair, else the Jaro distance) that tripped the warning.
  """
  @type warning :: %{
          group_ids: {Group.id(), Group.id()},
          names: {String.t(), String.t()},
          similarity: float()
        }

  # The Jaro-distance threshold above which two normalized names are flagged a
  # near-duplicate. Deliberately HIGH (advisory: precision over recall). A
  # normalized-equal pair is always flagged (similarity 1.0) regardless.
  @threshold 0.92

  @doc """
  The near-duplicate-name threshold (`String.jaro_distance/2` cutoff). Exposed so
  callers and tests can reference the documented value rather than hard-coding it.

  ## Examples

      iex> Kazi.Goal.GroupLint.threshold()
      0.92
  """
  @spec threshold() :: float()
  def threshold, do: @threshold

  @doc """
  Lints a goal's declared group NAMES for near-duplicates.

  Returns a (possibly empty) list of `warning/0` maps — one per near-duplicate
  PAIR, each naming both groups and the similarity that tripped it. ADVISORY: an
  empty list means no smell, a non-empty list is a review hint, NEITHER is a load
  failure. A goal with zero or one group yields `[]`.

  ## Examples

      iex> g = Kazi.Goal.new("g",
      ...>   groups: [
      ...>     Kazi.Goal.Group.new("identity-access", "Identity & Access"),
      ...>     Kazi.Goal.Group.new("identity", "Identity and Access")
      ...>   ])
      iex> [warning] = Kazi.Goal.GroupLint.warnings(g)
      iex> warning.names
      {"Identity & Access", "Identity and Access"}

      iex> g = Kazi.Goal.new("g",
      ...>   groups: [
      ...>     Kazi.Goal.Group.new("identity", "Identity"),
      ...>     Kazi.Goal.Group.new("billing", "Billing")
      ...>   ])
      iex> Kazi.Goal.GroupLint.warnings(g)
      []
  """
  @spec warnings(Goal.t()) :: [warning()]
  def warnings(%Goal{groups: groups}) do
    groups
    |> pairs()
    |> Enum.flat_map(fn {a, b} ->
      case similarity(a.name, b.name) do
        sim when sim >= @threshold ->
          [%{group_ids: {a.id, b.id}, names: {a.name, b.name}, similarity: sim}]

        _ ->
          []
      end
    end)
  end

  @doc """
  Normalizes a free-text group NAME into the form the fuzzy compare runs on:
  lower-cased, the `&`/`and` conjunction dropped, and any run of non-alphanumeric
  characters collapsed to a single space (trimmed). The same drift the id
  normalizer collapses, applied to the display name so `"Identity & Access"` and
  `"Identity and Access"` compare EQUAL.

  ## Examples

      iex> Kazi.Goal.GroupLint.normalize_name("Identity & Access")
      "identity access"

      iex> Kazi.Goal.GroupLint.normalize_name("Identity and Access")
      "identity access"

      iex> Kazi.Goal.GroupLint.normalize_name("  Sign-Up  ")
      "sign up"
  """
  @spec normalize_name(String.t()) :: String.t()
  def normalize_name(raw) when is_binary(raw) do
    raw
    |> String.downcase()
    |> String.replace("&", " ")
    |> String.replace(~r/\band\b/u, " ")
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  # The fuzzy similarity of two names: 1.0 when their normalized forms are equal
  # (a certain duplicate), else the Jaro distance of the normalized forms. Jaro on
  # an empty string is 0.0, so a name with no alphanumerics only ties another
  # all-empty one (handled by the equality branch), never a real name.
  defp similarity(name_a, name_b) do
    norm_a = normalize_name(name_a)
    norm_b = normalize_name(name_b)

    if norm_a == norm_b do
      1.0
    else
      String.jaro_distance(norm_a, norm_b)
    end
  end

  # Every unordered pair of groups (i < j), so each near-duplicate is reported
  # once, never as both (a, b) and (b, a) nor a group against itself.
  defp pairs(groups) do
    indexed = Enum.with_index(groups)

    for {a, i} <- indexed, {b, j} <- indexed, i < j, do: {a, b}
  end
end
