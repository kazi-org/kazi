defmodule Kazi.Goal.Group do
  @moduledoc """
  A single entry in a goal's declared *group taxonomy* (T12.1, ADR-0020).

  A large goal organizes its predicates as a tree — pillar → domain →
  capability — by declaring a flat `[[group]]` taxonomy and having predicates
  reference a group by `id`. Declaring the vocabulary once and referencing it by
  a stable slug is the structural fix for the operator's drift concern: a
  free-text group silently FRAGMENTS the hierarchy when spelling drifts
  ("Identity & Access" vs "Identity and Access"); a referenced-by-id taxonomy
  cannot (ADR-0020 §Decision).

  A group carries:

    * `id` — a stable, normalized slug (`"identity-access"`), the ONLY thing
      predicates reference. Authoring case / whitespace / `&` all normalize to
      one canonical id, so loosely-authored variants collapse rather than
      fragment. An explicit `id` is accepted and ALSO normalized, so the stored
      id is canonical regardless of how it was authored.
    * `name` — the human display label (`"Identity & Access"`), declared exactly
      once. Defaults to the source `id`/`name` string when no separate display
      label is authored.
    * `parent` — an optional parent group id (already normalized). The parent
      chain reconstructs the tree to arbitrary depth without nesting in the
      file. T12.1 PARSES and STORES `parent` verbatim (normalized); its
      reference-and-cycle validation is a separate task (T12.2) — this module
      does not validate that the parent exists or that the chain is acyclic.
    * `budget` — an optional per-group cap (iterations / cost). A group's
      effective budget is DERIVED (the sum of its descendants' budgets, tightened
      by an explicit cap), not stored hand-maintained; T12.1 only parses and
      stores the declared cap. Default `nil` (no declared cap).

  The struct is the in-memory shape the loader (`Kazi.Goal.Loader`) builds the
  taxonomy into and the read-model / exporter (ADR-0020 §Decision 5) build
  against. Like `Kazi.Predicate`, a `Group` is a pure declaration — it carries no
  evaluation behavior.
  """

  @typedoc "A normalized group id (slug). Lower-cased, hyphenated, `&` → `and`."
  @type id :: String.t()

  @typedoc """
  A declared per-group budget cap (iterations / cost). `nil` = no declared cap;
  the effective rollup is derived elsewhere (ADR-0020 §Decision 1). Stored
  verbatim by T12.1.
  """
  @type budget :: integer() | nil

  @type t :: %__MODULE__{
          id: id(),
          name: String.t(),
          parent: id() | nil,
          budget: budget()
        }

  @enforce_keys [:id, :name]
  defstruct id: nil,
            name: nil,
            parent: nil,
            budget: nil

  @doc """
  Normalizes a loosely-authored group identifier into a canonical slug.

  Case, surrounding/inner whitespace, and the conjunction (`&` or the word
  `and`) all collapse to one form, so variants an author might type
  interchangeably resolve to the SAME id and the hierarchy cannot fragment on
  spelling:

    * lower-cased;
    * the conjunction is dropped — both `&` and a standalone word `and` are
      elided, so "Identity & Access", "Identity and Access", and
      "identity-access" all agree (ADR-0020 §Context: the `&`-vs-`and` drift is
      the named failure mode);
    * any run of non-alphanumeric characters → a single hyphen;
    * leading / trailing hyphens trimmed.

  Pure and total. Used by the loader to normalize both an explicit `id` and a
  `parent` reference, so a stored id is always canonical regardless of authoring.

  ## Examples

      iex> Kazi.Goal.Group.normalize_id("Identity & Access")
      "identity-access"

      iex> Kazi.Goal.Group.normalize_id("Identity and Access")
      "identity-access"

      iex> Kazi.Goal.Group.normalize_id("  Sign  Up  ")
      "sign-up"

      iex> Kazi.Goal.Group.normalize_id("identity-access")
      "identity-access"
  """
  @spec normalize_id(String.t()) :: id()
  def normalize_id(raw) when is_binary(raw) do
    raw
    |> String.downcase()
    # Drop the conjunction (both the glyph and the standalone word) so `&`/`and`
    # variants converge. The word is matched only as a whole token (word
    # boundaries), so "android" or "andes" keep their letters.
    |> String.replace("&", " ")
    |> String.replace(~r/\band\b/u, " ")
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc """
  Builds a group.

  `id` and `name` are required. The `id` is normalized to a canonical slug
  (`normalize_id/1`); `name` is the display label, kept verbatim. Optional opts:
  `:parent` (a parent group id — normalized; reference-validated in T12.2) and
  `:budget` (an optional per-group cap, stored verbatim).

  ## Examples

      iex> g = Kazi.Goal.Group.new("Identity & Access", "Identity & Access")
      iex> {g.id, g.name}
      {"identity-access", "Identity & Access"}

      iex> g = Kazi.Goal.Group.new("capability", "Capability",
      ...>   parent: "Identity & Access", budget: 5)
      iex> {g.parent, g.budget}
      {"identity-access", 5}
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(id, name, opts \\ []) when is_binary(id) and is_binary(name) do
    %__MODULE__{
      id: normalize_id(id),
      name: name,
      parent: normalize_parent(Keyword.get(opts, :parent)),
      budget: Keyword.get(opts, :budget)
    }
  end

  defp normalize_parent(nil), do: nil
  defp normalize_parent(parent) when is_binary(parent), do: normalize_id(parent)
end
