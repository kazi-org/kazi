defmodule Kazi.Reconcile.Coverage do
  @moduledoc """
  The **surface-coverage meta-predicate** (ADR-0021, decision 3): the dead-code /
  `A \\ I` half of "correct software with no dead code".

  Given the scanned public surface `A` (a list of
  `Kazi.Reconcile.SurfaceElement`, from `Kazi.Reconcile.SurfaceScanner`) and the
  **intended** predicate set `I` (a list of `Kazi.Predicate`), this asserts the
  one invariant ADR-0021 names:

  > **every surface element is OWNED by >=1 intended predicate.**

  An element that no intended predicate owns is **unowned** — dead code or
  undocumented surface. The meta-predicate FAILS and *names* every unowned
  element; it never deletes anything. ADR-0021 is explicit about the posture:
  *warn, don't auto-delete*. Removing the element, or adding the predicate that
  justifies it, is reconciliation work for a human/agent, surfaced like any other
  failing predicate — not an action this module takes.

  ## How a predicate "owns" an element

  Ownership is a deliberately simple, documented, *approximate* string match —
  the surface scan itself is approximate (`docs/lore.md` L-0006), so a precise
  matcher would be false precision. A predicate `p` owns an element `e` iff any
  **owner token** derived from `p` matches `e.identifier`:

    * `:http_probe` — the request route. From `config.url` we take the URL *path*
      (e.g. `https://x/healthz?q=1` → `/healthz`) and, with `config.method`,
      build a `"VERB /path"` token (`"GET /healthz"`). Both the bare path and the
      verb+path are owner tokens, so they match an `:http_route` element written
      either way.
    * `:tests` / `:custom_script` — the command tokens: `config.cmd` and each of
      `config.args` (e.g. `cmd: "mix", args: ["test", "test/foo_test.exs"]`).
      These match `:exported_function` / `:mix_task` elements by the module or
      task name appearing in the command (`"mix surface.greet"` matches the
      `mix_task` of the same identifier).
    * **any kind** — the predicate's own `id` and `description` are also owner
      tokens, plus every *string* value in `config`. This is the catch-all: a
      predicate that names the symbol it covers (in its id, description, or a
      config value) owns it, regardless of provider kind. It is what makes a
      hand-written predicate able to claim an arbitrary surface element.

  A token *matches* an identifier when, after trimming, the two are equal or
  either contains the other as a substring (case-sensitive). Empty/blank tokens
  never match. This is intentionally generous: a false *negative* (real surface
  flagged dead) erodes trust and is caught by the allow-list; a false *positive*
  (dead surface claimed owned) is the lesser harm and is recoverable as the
  intended set tightens.

  ## Allow-list

  ADR-0021 mandates an explicit allow-list for intentional un-predicated surface
  (internal/debug, dynamically-dispatched entry points L-0006). An element whose
  `identifier` matches an allow-list pattern is **allowed**: it counts as covered
  and is reported separately from owned elements (so the result records *why* it
  passed). Patterns are plain strings with an optional trailing `*` wildcard:

    * `"Kazi.Internal.Debug.dump/1"` — exact identifier.
    * `"Kazi.Internal.*"` — any identifier starting with `"Kazi.Internal."`.
    * `"mix kazi.*"` — any matching Mix task.

  ## Result shape

  `check/3` returns a `Kazi.Reconcile.Coverage.Result`:

    * `status` — `:pass` when no element is unowned, else `:fail`. An **empty
      surface** passes vacuously (nothing to own). An **empty intended set** does
      NOT crash: every (non-allow-listed) element is simply unowned and named.
    * `unowned` — the named dead-code elements (empty on `:pass`).
    * `owned` — elements owned by >=1 predicate.
    * `allowed` — elements covered by the allow-list.

  Every input element lands in exactly one of `unowned` / `owned` / `allowed`,
  and the three partition the de-duplicated surface. The result is a plain
  reporting value; mapping it onto a `Kazi.PredicateResult` (so the meta-predicate
  rides the normal convergence loop) is the caller's job.
  """

  alias Kazi.Predicate
  alias Kazi.Reconcile.{SurfaceElement, SurfaceMatch}

  defmodule Result do
    @moduledoc """
    The outcome of a surface-coverage check (`Kazi.Reconcile.Coverage.check/3`).

    `status` is `:pass` iff `unowned` is empty. `owned`, `allowed`, and `unowned`
    partition the de-duplicated input surface, each sorted by
    `Kazi.Reconcile.SurfaceElement.sort_key/1` for a deterministic report.
    """

    @type t :: %__MODULE__{
            status: :pass | :fail,
            owned: [SurfaceElement.t()],
            allowed: [SurfaceElement.t()],
            unowned: [SurfaceElement.t()]
          }

    @enforce_keys [:status]
    defstruct status: :pass, owned: [], allowed: [], unowned: []

    @doc "The identifiers of the unowned (dead-code) elements, sorted."
    @spec unowned_identifiers(t()) :: [String.t()]
    def unowned_identifiers(%__MODULE__{unowned: unowned}) do
      Enum.map(unowned, & &1.identifier)
    end
  end

  @doc """
  Checks that every surface element is owned by >=1 intended predicate or covered
  by the allow-list.

    * `surface` — the scanned inventory `A` (`[SurfaceElement.t()]`).
    * `predicates` — the intended set `I` (`[Predicate.t()]`).
    * `opts`:
      * `:allow_list` — patterns (see moduledoc) for intentional un-predicated
        surface. Defaults to `[]`.

  Returns a `Coverage.Result`. Pure and total: an empty surface, an empty
  intended set, or `nil`/`%{}` predicate configs are all handled without raising
  (an empty intended set yields every non-allow-listed element as `unowned`).

  ## Examples

      iex> alias Kazi.Reconcile.SurfaceElement
      iex> el = SurfaceElement.new(:mix_task, "mix surface.greet", "lib/mix/tasks/greet.ex")
      iex> p = Kazi.Predicate.new(:greet, :tests, config: %{cmd: "mix", args: ["surface.greet"]})
      iex> Kazi.Reconcile.Coverage.check([el], [p]).status
      :pass

      iex> alias Kazi.Reconcile.SurfaceElement
      iex> el = SurfaceElement.new(:exported_function, "Dead.code/0", "lib/dead.ex", 1)
      iex> r = Kazi.Reconcile.Coverage.check([el], [])
      iex> {r.status, Enum.map(r.unowned, & &1.identifier)}
      {:fail, ["Dead.code/0"]}
  """
  @spec check([SurfaceElement.t()], [Predicate.t()], keyword()) :: Result.t()
  def check(surface, predicates, opts \\ [])
      when is_list(surface) and is_list(predicates) and is_list(opts) do
    allow_patterns = Keyword.get(opts, :allow_list, [])

    owner_tokens =
      predicates |> Enum.flat_map(&owner_tokens/1) |> SurfaceMatch.trim_tokens()

    {allowed, rest} =
      surface
      |> Enum.uniq()
      |> Enum.split_with(&SurfaceMatch.allowed?(&1, allow_patterns))

    {owned, unowned} = Enum.split_with(rest, &SurfaceMatch.covered?(&1, owner_tokens))

    %Result{
      status: if(unowned == [], do: :pass, else: :fail),
      owned: SurfaceMatch.sort(owned),
      allowed: SurfaceMatch.sort(allowed),
      unowned: SurfaceMatch.sort(unowned)
    }
  end

  # --- ownership -----------------------------------------------------------

  # All owner tokens a predicate contributes: provider-specific tokens plus the
  # universal id/description/config-strings catch-all.
  defp owner_tokens(%Predicate{} = p) do
    kind_tokens(p) ++ generic_tokens(p)
  end

  defp kind_tokens(%Predicate{kind: :http_probe, config: config}) do
    case path_and_method(config) do
      {nil, _method} -> []
      {path, method} -> [path, "#{method} #{path}"]
    end
  end

  defp kind_tokens(%Predicate{kind: kind, config: config})
       when kind in [:tests, :custom_script] do
    cmd = config_get(config, :cmd)
    args = config_get(config, :args)
    args = if is_list(args), do: args, else: []
    [cmd | args]
  end

  defp kind_tokens(%Predicate{}), do: []

  # The catch-all: the predicate's id, description, and every string config value
  # become owner tokens, so a predicate naming its surface owns it regardless of
  # kind.
  defp generic_tokens(%Predicate{id: id, description: description, config: config}) do
    [to_token(id), description | config_string_values(config)]
  end

  defp config_string_values(config) when is_map(config) do
    config
    |> Map.values()
    |> Enum.filter(&is_binary/1)
  end

  defp config_string_values(_), do: []

  defp config_get(config, key) when is_map(config), do: Map.get(config, key)
  defp config_get(_, _), do: nil

  defp to_token(id) when is_binary(id), do: id
  defp to_token(id) when is_atom(id) and not is_nil(id), do: Atom.to_string(id)
  defp to_token(_), do: nil

  # The URL path (no scheme/host/query) and the request method, for an
  # http_probe. A missing/blank url yields `{nil, _}` (no route token).
  defp path_and_method(config) do
    method = config |> config_get(:method) |> method_token()

    path =
      case config_get(config, :url) do
        url when is_binary(url) and url != "" -> url_path(url)
        _ -> nil
      end

    {path, method}
  end

  defp url_path(url) do
    case URI.parse(url).path do
      p when is_binary(p) and p != "" -> p
      # A bare host with no path (`http://x`) — treat root as the route.
      _ -> "/"
    end
  end

  defp method_token(nil), do: "GET"

  defp method_token(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp method_token(method) when is_binary(method),
    do: method |> String.trim() |> String.upcase()

  defp method_token(_), do: "GET"
end
