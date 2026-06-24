defmodule Kazi.Reconcile.ProseImporter do
  @moduledoc """
  Imports the *intended set* `I` from a PROSE doc — an ADR, requirements, or
  design doc — via the harness (ADR-0021, decision 1, the prose path; T13.3).

  Intent that lives only in prose cannot be parsed deterministically the way an
  OpenAPI spec or a gherkin feature can. ADR-0021 therefore routes prose through
  the EXISTING human-reviewed authoring path: the coding harness DRAFTS candidate
  acceptance predicates, and a human APPROVES them — never silently trusted. This
  module is the thin front-end that hands a prose doc's text to that path; it does
  NOT fork a parallel authoring mechanism. `Kazi.Authoring.propose/2` stays the
  single write path (ADR-0023): the same clarify floor, the same `proposed → approve`
  gate, the same persisted shape the CLI rehydrates.

  ## What it does

  `import/2` reads a prose doc's text and drives `Kazi.Authoring.propose/2` with
  that text as the *idea*. The result is a `proposed` `Kazi.Authoring.Draft` —
  candidate predicates a reviewer then `approve`s, `reject`s, or `edit`s through
  the same workflow any other proposal uses (`Kazi.Authoring.approve/2` etc.).
  Nothing is accepted without that approval; this importer only produces the
  `proposed` draft.

  The harness is the INJECTABLE seam (`Kazi.Authoring`'s `:harness` opt → `run/3`),
  so tests inject a stub adapter and no real `claude` (or network) is driven. The
  deterministic clarify floor (ADR-0019) still applies: pass an `:ask` callback to
  exercise it, exactly as a direct `propose/2` caller would.

  ## Doc vs idea

  The whole prose doc becomes the idea text the harness drafts from. A short
  human-legible goal id and review handle are still DERIVED from the leading words
  (by `Kazi.Authoring`), so a long doc does not produce a giant id; pass `:id` /
  `:proposal_ref` to pin them when importing several docs that share a prefix.

  ## Reading the doc

  `import/2` takes the doc as a STRING (already-read text). `import_file/2` reads a
  path off disk first (the only I/O in this module) and then delegates to
  `import/2`, so the harness-driving core stays pure over its text input and is the
  unit-tested seam. A blank doc is `{:error, :empty_doc}`; an unreadable path is
  `{:error, {:read_failed, posix}}`.
  """

  alias Kazi.Authoring

  @typedoc """
  Options for `import/2` and `import_file/2`. Forwarded VERBATIM to
  `Kazi.Authoring.propose/2`, so every authoring opt applies unchanged — notably:

    * `:harness` — the injected harness adapter (the test seam; default the real
      `Kazi.Harness.ClaudeAdapter`).
    * `:ask` — the clarify-phase callback (ADR-0019); when present the
      deterministic floor questions are asked before drafting.
    * `:workspace`, `:adapter_opts`, `:model` — passed through to the harness.
    * `:id` / `:proposal_ref` — pin the derived goal id / review handle.
    * `:proposal` — caller-drafts (ADR-0023 decision 4): supply the predicates
      directly and the harness is not driven.

  Plus this module's own option:

    * `:title` — a short label PREPENDED to the doc text as a heading, so the
      harness sees what the doc is for. Optional; the doc text is used as-is when
      omitted.
  """
  @type opts :: keyword()

  @doc """
  Imports a prose doc (its `text`) into a `proposed` draft via `Kazi.Authoring`.

  Drives the injectable harness to draft candidate acceptance predicates from the
  doc text, routed through the SAME write path, clarify floor, and `proposed`
  status the CLI's `propose` uses — so the draft is HUMAN-REVIEWED (approve /
  reject / edit) before it can ever run. Returns `{:ok, %Kazi.Authoring.Draft{}}`
  (status `:proposed`) or `{:error, reason}`:

    * `{:error, :empty_doc}` — the doc text was blank.
    * any `Kazi.Authoring.propose/2` error (`{:harness_failed, _}`,
      `{:invalid_proposal, _}`, `%Ecto.Changeset{}`, …).

  ## Examples

      iex> defmodule DocHarness do
      ...>   @behaviour Kazi.HarnessAdapter
      ...>   @impl true
      ...>   def run(_prompt, _workspace, _opts) do
      ...>     {:ok, %{result: ~s({"name":"From the ADR","predicates":[{"id":"probe","provider":"http_probe"}]})}}
      ...>   end
      ...> end
      iex> {:ok, draft} = Kazi.Reconcile.ProseImporter.import("# ADR\\nThe service must expose /healthz.", harness: DocHarness)
      iex> {draft.status, draft.goal.mode, length(draft.goal.predicates)}
      {:proposed, :create, 1}
  """
  @spec import(String.t(), opts()) :: {:ok, Authoring.Draft.t()} | {:error, term()}
  def import(text, opts \\ []) when is_binary(text) and is_list(opts) do
    {title, propose_opts} = Keyword.pop(opts, :title)

    case build_idea(text, title) do
      {:ok, idea} -> Authoring.propose(idea, propose_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads a prose doc off disk at `path` and imports it (see `import/2`).

  The only I/O in this module: it reads the file, then delegates to `import/2`
  with the same opts. A `:title` is defaulted to the file's basename when not
  supplied, so a draft from `docs/adr/0001-foo.md` is labelled with that name.
  Returns `{:ok, %Kazi.Authoring.Draft{}}` or `{:error, reason}`:

    * `{:error, {:read_failed, posix}}` — the path could not be read.
    * any `import/2` error.
  """
  @spec import_file(Path.t(), opts()) :: {:ok, Authoring.Draft.t()} | {:error, term()}
  def import_file(path, opts \\ []) when is_binary(path) and is_list(opts) do
    case File.read(path) do
      {:ok, text} ->
        __MODULE__.import(text, Keyword.put_new(opts, :title, Path.basename(path)))

      {:error, posix} ->
        {:error, {:read_failed, posix}}
    end
  end

  # Assemble the idea text the harness drafts from: an optional title heading over
  # the doc body. A blank doc (after trimming) is rejected here, mirroring
  # `Kazi.Authoring`'s `:empty_idea` guard but reported as `:empty_doc` so the
  # caller knows the doc — not a bare idea — was the empty input.
  @spec build_idea(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, :empty_doc}
  defp build_idea(text, title) do
    case String.trim(text) do
      "" -> {:error, :empty_doc}
      body -> {:ok, prepend_title(body, title)}
    end
  end

  defp prepend_title(body, title) when is_binary(title) do
    case String.trim(title) do
      "" -> body
      heading -> "# #{heading}\n\n#{body}"
    end
  end

  defp prepend_title(body, _title), do: body
end
