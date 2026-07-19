defmodule Kazi.Adopt do
  @moduledoc """
  Reverse-engineers a starter goal-file from an existing repo (T5.1, UC-023,
  ADR-0013): point kazi at a project that already works and have it derive the
  project's current checkable surface — the equivalent of `terraform import` or
  `tsc --init`.

  `detect/1` is the deterministic **stack + test-command** detector: it inspects
  the repo's marker files and maps them to a `test_runner` predicate spec plus
  stack metadata. It is the first step of `kazi init` (the writer T5.3 renders the
  detected goal to a goal-file; guards T5.2 and the CLI T5.5 build on top).

  ## What it detects

  A marker file at the repo root maps to a test command (ADR-0013 §1):

  | Marker file                  | Stack     | `cmd`    | `args`             |
  |------------------------------|-----------|----------|--------------------|
  | `go.mod`                     | `:go`     | `go`     | `["test", "./..."]`|
  | `mix.exs`                    | `:elixir` | `mix`    | `["test"]`         |
  | `package.json` (+`test` script) | `:node` | derived  | derived            |
  | `pyproject.toml`/`setup.cfg` | `:python` | `pytest` | `[]`               |

  For `package.json` the test command is read from `scripts.test`: an `npm test`
  script yields `cmd: "npm", args: ["test"]`; a script invoking another runner
  (`vitest`, `jest`, …) yields that runner directly so the derived command is the
  one the project actually runs. A `package.json` with **no** `test` script (or
  the conventional placeholder that exits non-zero) is treated as no-detection for
  the test predicate — kazi will not emit a command that is not really a test.

  Detection is ordered (Go, Elixir, Node, Python) so a polyglot repo resolves
  deterministically to a single primary stack. The first marker that yields a
  usable test command wins.

  ## Result shape

  On detection, an `%{stack: atom(), predicate: map()}` where `:predicate` is a
  goal-file predicate **map** in exactly the shape `Kazi.Goal.Loader.from_map/1`
  accepts (string keys, `provider: "test_runner"`, the `:cmd`/`:args` spread as
  sibling keys the loader collects into the predicate's `config`). Rendering and
  loading therefore round-trip through the same validated loader the CLI uses; no
  bespoke deserialiser.

  On no detection, `{:error, :no_stack_detected}` — a clear tagged result, never a
  crash, so the caller (the CLI T5.5) can report "could not detect a stack" rather
  than failing opaquely.

  ## Hermeticity

  `detect/1` reads marker files through an **injectable file-reader seam**
  (`:file_reader`, defaulting to `File`), consistent with the repo-introspection
  pattern in `Kazi.Context.RepoMapSource` (ADR-0010): a pure function over a root
  path, no `System.cmd`, no network, no git clone. Tests point it at a fixture
  repo dir (or inject an in-memory reader) and assert the derived command. The
  same repo at the same revision always yields the same result.

  ## Optional harness ENRICHMENT (off by default)

  `enrich/2` is the **opt-in** second step (ADR-0013 §4): behind an explicit
  `enrich: true` flag, kazi drives the coding harness to propose live
  `http_probe`/`browser` predicates from the repo's discovered endpoints, merging
  them into a `detect/1` result alongside the deterministic `test_runner`
  predicate. It is wired through the **same injectable harness seam used
  everywhere else** (`Kazi.HarnessAdapter.run/3`, the `:harness` opt defaulting to
  the real `Kazi.Harness.ClaudeAdapter`) — exactly the pattern `Kazi.Authoring`
  uses — so tests inject a stub adapter and no real `claude` (or network) is
  touched.

  With enrichment **off** (the default), `enrich/2` is byte-identical to the
  `detect/1` it wraps: the deterministic detection only, no harness call. The
  on-path is non-deterministic by nature — the agent proposes live predicates from
  what it discovers — which is exactly why it is opt-in and clearly separated from
  the deterministic path (ADR-0013 §4 consequences). Proposed predicates are
  validated to be **loadable-shaped** (they round-trip through
  `Kazi.Goal.Loader.from_map/1`) before being merged, so enrichment can only ever
  add predicates a goal-file could load.
  """

  @typedoc """
  A detected stack: the marker family kazi recognised. `:unknown` is never
  returned (no-detection is the `{:error, :no_stack_detected}` tuple) but is
  reserved for callers that want to name the absence.
  """
  @type stack :: :go | :elixir | :node | :python | :unknown

  @typedoc """
  A successful detection: the recognised `:stack` and a goal-file `:predicate`
  map (the shape `Kazi.Goal.Loader.from_map/1` accepts).
  """
  @type detection :: %{stack: stack(), predicate: map()}

  # Guard predicate ids. Stable so a re-run of `kazi init` produces the same
  # goal-file (deterministic, ADR-0013 §2).
  @baseline_guard_id "tests-pass-baseline"
  @coverage_guard_id "coverage-ratchet"

  # Per-stack coverage detection: a list of `{marker, needle}` pairs. A coverage
  # guard is emitted only when one of the stack's config/marker files is present
  # AND contains the coverage-tool needle (case-sensitive substring). Conservative
  # by construction — absence of the config means no coverage guard (ADR-0013 §2,
  # "when in doubt, emit fewer predicates"). The needles are tool names that
  # appear verbatim in the declaring file:
  #
  #   * Elixir: `excoveralls` listed in mix.exs deps.
  #   * Node:   `nyc`, `c8`, or `--coverage` (jest/vitest) in package.json.
  #   * Python: `pytest-cov` / `coverage` in pyproject.toml or setup.cfg.
  #   * Go:     coverage is built into `go test -cover` (no config marker), so it
  #     is handled separately below rather than via a config probe.
  @coverage_markers %{
    elixir: [{"mix.exs", "excoveralls"}],
    node: [
      {"package.json", "nyc"},
      {"package.json", "c8"},
      {"package.json", "--coverage"}
    ],
    python: [
      {"pyproject.toml", "pytest-cov"},
      {"pyproject.toml", "coverage"},
      {"setup.cfg", "pytest-cov"},
      {"setup.cfg", "coverage"}
    ]
  }

  # The predicate id every adopted test_runner carries. Stable so a re-run of
  # `kazi init` produces the same goal-file (deterministic, ADR-0013).
  @predicate_id "tests-pass"

  # Marker files probed in order; the first that yields a usable test command
  # wins. Ordering makes a polyglot repo resolve deterministically.
  @markers [
    {:go, "go.mod"},
    {:elixir, "mix.exs"},
    {:node, "package.json"},
    {:python, "pyproject.toml"},
    {:python, "setup.cfg"}
  ]

  @doc """
  Detects the stack and test command for the repo rooted at `path`.

  Returns `{:ok, %{stack: stack, predicate: predicate_map}}` when a marker file
  yields a usable test command, or `{:error, :no_stack_detected}` when no marker
  is present (or, for Node, no usable `test` script). Pure, deterministic, and
  hermetic — reads marker files through the injectable `:file_reader` seam (no
  shelling out, no network).

  ## Options

    * `:file_reader` — the filesystem seam. Either a **module** exposing
      `regular?/1` and `read/1` (the `File` contract — the default is `File`), or
      a `{module, state}` tuple whose module exposes `regular?/2` and `read/2`
      (called as `module.regular?(state, path)`). The tuple form lets tests inject
      a stateful in-memory reader and stay hermetic without touching disk.

  ## Examples

  A repo whose root holds a `go.mod` detects the Go stack and `go test ./...`:

      {:ok, %{stack: :go, predicate: predicate}} = Kazi.Adopt.detect("/path/to/repo")
      predicate["cmd"]  #=> "go"
      predicate["args"] #=> ["test", "./..."]

  A repo with no recognised marker is a clear no-detection (not a crash):

      Kazi.Adopt.detect("/path/to/empty/repo") #=> {:error, :no_stack_detected}
  """
  @spec detect(Path.t(), keyword()) :: {:ok, detection()} | {:error, :no_stack_detected}
  def detect(path, opts \\ []) when is_binary(path) and is_list(opts) do
    reader = Keyword.get(opts, :file_reader, File)

    @markers
    |> Enum.find_value(fn {stack, marker} ->
      with true <- present?(reader, path, marker),
           {:ok, cmd, args} <- command_for(reader, path, marker) do
        {stack, cmd, args}
      else
        _ -> nil
      end
    end)
    |> case do
      {stack, cmd, args} -> {:ok, %{stack: stack, predicate: predicate_map(cmd, args)}}
      nil -> {:error, :no_stack_detected}
    end
  end

  @doc """
  Derives conservative GUARD predicates from a detected stack (ADR-0013 §2).

  Takes the `detect/1` result (`%{stack: stack, predicate: map}`) and returns a
  list of guard predicate **maps**, each in exactly the shape
  `Kazi.Goal.Loader.from_map/1` accepts (string keys, `"guard" => true`, so they
  round-trip into the goal's `guards`). Guards are invariants kazi enforces so
  the adopted goal *does not regress what already works*.

  Two guards are possible, both evaluated by the existing `test_runner` provider
  (the only provider that runs a command and maps its exit code to pass/fail — so
  every emitted guard is one kazi can actually evaluate, never an invented one):

    * a **baseline `tests-pass` guard** — always emitted for a detected stack. It
      reuses the detected test command (the same `:cmd`/`:args` as the detection's
      acceptance predicate) as an invariant: the suite must keep passing.

    * a **coverage-ratchet guard** — emitted ONLY when a coverage tool is
      deterministically detectable in the stack's config files (e.g. Elixir
      `excoveralls` in `mix.exs`; Node `nyc`/`c8`/`--coverage` in `package.json`;
      Python `pytest-cov`/`coverage` in `pyproject.toml`/`setup.cfg`). The guard
      runs the coverage tool's command, which exits non-zero when coverage falls
      below the project's configured floor. When no coverage tool is present,
      **only the baseline is returned** — when in doubt, emit fewer predicates.

  Coverage detection reads config files through the same injectable
  `:file_reader` seam as `detect/1` (a bare `File`-contract module or a
  `{module, state}` tuple), so `guards/1` is pure, deterministic, and hermetic:
  no `System.cmd`, no network. The same repo at the same revision always yields
  the same guard list.

  ## Options

    * `:file_reader` — the filesystem seam, as in `detect/1` (defaults to `File`).

  ## Examples

  An Elixir stack listing `excoveralls` yields both guards:

      {:ok, detection} = Kazi.Adopt.detect(repo)
      [baseline, coverage] = Kazi.Adopt.guards(detection, file_reader: reader)
      baseline["guard"]  #=> true
      coverage["id"]     #=> "coverage-ratchet"

  A stack with no coverage tool yields only the baseline:

      [baseline] = Kazi.Adopt.guards(detection)
      baseline["provider"] #=> "test_runner"
  """
  @spec guards(detection(), keyword()) :: [map()]
  def guards(detection, opts \\ [])

  def guards(%{stack: stack, predicate: %{} = predicate}, opts) when is_list(opts) do
    reader = Keyword.get(opts, :file_reader, File)
    path = Keyword.get(opts, :path, ".")

    [baseline_guard(predicate) | coverage_guards(stack, reader, path)]
  end

  # A baseline `tests-pass` guard: the detected test command, re-expressed as an
  # invariant (`"guard" => true`). It reuses the detection's `test_runner` cmd/args
  # so kazi enforces "the suite keeps passing" with a provider it already has.
  defp baseline_guard(%{"cmd" => cmd, "args" => args}) do
    %{
      "id" => @baseline_guard_id,
      "provider" => "test_runner",
      "description" => "project test suite keeps passing (baseline regression guard)",
      "guard" => true,
      "cmd" => cmd,
      "args" => args
    }
  end

  # A coverage-ratchet guard — emitted only when the stack's coverage tool is
  # detectable in a config file via the file_reader seam. Returns a one- or
  # zero-element list so the caller can splat it after the baseline. Conservative:
  # an undetectable or unmapped stack (e.g. Go, no config marker) yields [].
  defp coverage_guards(stack, reader, path) do
    case coverage_tool(stack, reader, path) do
      {:ok, cmd, args, tool} -> [coverage_guard(cmd, args, tool)]
      :none -> []
    end
  end

  defp coverage_guard(cmd, args, tool) do
    %{
      "id" => @coverage_guard_id,
      "provider" => "test_runner",
      "description" => "test coverage does not regress (#{tool} ratchet)",
      "guard" => true,
      "cmd" => cmd,
      "args" => args
    }
  end

  # Probes the stack's coverage markers in order; the first marker file present
  # AND containing the tool needle wins. Returns `{:ok, cmd, args, tool}` with the
  # command that runs the coverage tool (exit-non-zero below the configured floor),
  # or `:none`. Pure over the file_reader — no shelling out.
  defp coverage_tool(stack, reader, path) do
    @coverage_markers
    |> Map.get(stack, [])
    |> Enum.find_value(:none, fn {marker, needle} ->
      with {:ok, contents} <- read(reader, path, marker),
           true <- String.contains?(contents, needle) do
        coverage_command(stack, needle)
      else
        _ -> nil
      end
    end)
  end

  # Coverage-tool command per detected stack/needle. Each command runs the
  # project's coverage check, which exits non-zero when coverage drops below the
  # project's configured minimum — exactly what the test_runner provider maps to a
  # failing guard. The command is the one a developer runs locally.
  defp coverage_command(:elixir, "excoveralls"), do: {:ok, "mix", ["coveralls"], "excoveralls"}

  # nyc/c8 enforce a threshold with `--check-coverage` (exit non-zero below it);
  # a `--coverage` flag in the test script means `npm test` already measures it.
  defp coverage_command(:node, "nyc"),
    do: {:ok, "npx", ["nyc", "--check-coverage", "npm", "test"], "nyc"}

  defp coverage_command(:node, "c8"),
    do: {:ok, "npx", ["c8", "--check-coverage", "npm", "test"], "c8"}

  defp coverage_command(:node, "--coverage"), do: {:ok, "npm", ["test"], "coverage"}

  # pytest-cov enforces a floor with `--cov-fail-under` (read from the project's
  # config when set); `--cov` turns coverage measurement on.
  defp coverage_command(:python, needle) when needle in ["pytest-cov", "coverage"],
    do: {:ok, "pytest", ["--cov", "--cov-fail-under=0"], "pytest-cov"}

  @typedoc """
  An adopted result: the deterministic `detect/1` map (`:stack`, `:predicate`)
  optionally carrying a `:proposed` list of harness-proposed live predicate maps
  (each in the shape `Kazi.Goal.Loader.from_map/1` accepts). With enrichment off,
  `:proposed` is `[]`.
  """
  @type adoption :: %{stack: stack(), predicate: map(), proposed: [map()]}

  # The harness adapter driven when enrichment is on and the caller does not
  # inject one. The real `claude -p` adapter — the same default `Kazi.Authoring`
  # and the runtime use; tests inject a stub via the `:harness` opt (the seam), so
  # lib/ carries no stub.
  @default_harness Kazi.Harness.ClaudeAdapter

  # Provider strings enrichment may propose. The harness is asked for LIVE
  # predicates only; a proposed predicate naming any other provider (e.g.
  # `test_runner`, which detection already owns) is dropped.
  @enrich_providers ~w(http_probe browser)

  @doc """
  Adopts the repo at `path`: the deterministic `detect/1`, optionally **enriched**
  with harness-proposed live predicates (ADR-0013 §4).

  With enrichment **off** (the default), this is `detect/1` with an empty
  `:proposed` list — byte-identical detection, no harness call, fully
  deterministic. Pass `enrich: true` to opt in: kazi then drives the (injectable)
  harness to propose `http_probe`/`browser` predicates from the repo's discovered
  endpoints, validates each is loadable-shaped, and merges them under `:proposed`
  alongside the detected `test_runner` `:predicate`. The on-path is
  non-deterministic by nature (the agent proposes from what it discovers), which
  is why it is opt-in.

  Returns `{:ok, %{stack: stack, predicate: predicate_map, proposed: [predicate_map]}}`
  on detection, or `{:error, :no_stack_detected}` when no marker is present.
  Enrichment never fails the adoption: if the harness errors or proposes nothing
  usable, `:proposed` is simply `[]` and the deterministic detection still stands.

  ## Options

  In addition to `detect/2`'s `:file_reader`:

    * `:enrich` — opt into harness enrichment (default `false`). Off ⇒ no harness
      call, deterministic output.
    * `:harness` — the `Kazi.HarnessAdapter` module to drive (default the real
      `Kazi.Harness.ClaudeAdapter`). The injection seam: tests pass a stub.
    * `:adapter_opts` — keyword opts forwarded verbatim to the harness `run/3`
      (e.g. a stub's control pid, a model).

  ## Examples

  Off by default — the deterministic detection with no proposals:

      {:ok, %{stack: :go, proposed: []}} = Kazi.Adopt.adopt("/path/to/repo")

  Opted in with a stub harness, proposed live predicates are merged:

      {:ok, %{proposed: [probe | _]}} =
        Kazi.Adopt.adopt("/path/to/repo", enrich: true, harness: StubHarness)
      probe["provider"] #=> "http_probe"
  """
  @spec adopt(Path.t(), keyword()) :: {:ok, adoption()} | {:error, :no_stack_detected}
  def adopt(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, detection} <- detect(path, opts) do
      {:ok, Map.put(detection, :proposed, enrich(path, detection, opts))}
    end
  end

  @doc """
  The single `spec_coverage` predicate map `kazi init --discover` writes (T41.4,
  ADR-0054 / UC-053).

  A discovery goal's SOLE predicate is the manifest-coverage check
  (`Kazi.Providers.SpecCoverage`, T41.3): "is every public surface element
  referenced by >=1 Scenario across the product's `.feature` specs?" On a repo
  with no `.feature` files yet the whole surface is uncovered, so this predicate
  starts RED — the honest starting state a discovery run drives down.

  It is a plain acceptance predicate (not a guard) in the string-keyed shape
  `Kazi.Goal.Loader.from_map/1` accepts. Config is left at the provider's
  documented defaults (features glob `docs/specs/**/*.feature`, the default
  surface scan), so the authored goal-file stays minimal and the human edits the
  glob only if their specs live elsewhere.
  """
  @spec spec_coverage_predicate() :: %{optional(String.t()) => term()}
  def spec_coverage_predicate do
    %{
      "id" => "spec-coverage",
      "provider" => "spec_coverage",
      "description" =>
        "every public surface element is referenced by >=1 Scenario across the product's .feature specs"
    }
  end

  @doc """
  Returns the harness-proposed live predicate maps for `path`, or `[]`.

  OFF by default: with `enrich: false` (or absent) this returns `[]` without
  touching the harness — the determinism guarantee of the adopt off-path. With
  `enrich: true` it drives the injectable harness seam (`:harness`, default the
  real `Kazi.Harness.ClaudeAdapter`) via `run/3` — the same seam `Kazi.Authoring`
  and the convergence loop use — asking it to propose `http_probe`/`browser`
  predicates from the repo's discovered endpoints, and returns the subset that is
  loadable-shaped (each round-trips through `Kazi.Goal.Loader.from_map/1`).

  Enrichment is best-effort: a harness error, an unparseable proposal, or a
  proposal carrying no usable live predicate all collapse to `[]` rather than
  failing the adoption (the deterministic detection always stands).

  `detection` is the `detect/1` result; it is accepted so the prompt can name the
  detected stack, and so enrichment composes onto a detection the caller already
  has.
  """
  @spec enrich(Path.t(), detection(), keyword()) :: [map()]
  def enrich(path, detection, opts \\ [])
      when is_binary(path) and is_map(detection) and is_list(opts) do
    if Keyword.get(opts, :enrich, false) do
      drive_enrichment(path, detection, opts)
    else
      []
    end
  end

  @doc """
  Renders an adopted goal **map** (the `Kazi.Goal.Loader.from_map/1` shape) to a
  TOML goal-file STRING (T5.3, ADR-0013, ADR-0015).

  Delegates to `Kazi.Adopt.Writer.to_toml/2` — the deterministic hand-renderer
  that emits the goal-file subset `kazi init` writes (top-level `id`/`name`, an
  optional `[scope]`, the `[[predicate]]` blocks incl. guards), an optional
  COMMENTED T48.9 learned-`[budget]`-suggestion block (`suggested_budget`,
  default `nil` — see `Kazi.Economy.BudgetSuggestion`), and appends a COMMENTED
  live-predicate scaffold (an `http_probe` with `TODO` placeholders for a human
  to fill in). Pure and deterministic: the same inputs render byte-identically,
  and decoding the uncommented part round-trips through
  `Kazi.Goal.Loader.from_map/1`.
  """
  @spec to_toml(map(), Kazi.Economy.BudgetSuggestion.t() | nil) :: String.t()
  defdelegate to_toml(map, suggested_budget \\ nil), to: Kazi.Adopt.Writer

  # Drive the injectable harness for live-predicate proposals. Any failure path
  # (harness error, unparseable payload, no usable predicate) yields `[]` — the
  # deterministic detection always stands, so enrichment can only ever ADD.
  defp drive_enrichment(path, detection, opts) do
    {harness, harness_opts} = resolve_harness(opts)
    adapter_opts = Keyword.merge(Keyword.get(opts, :adapter_opts, []), harness_opts)
    prompt = enrich_prompt(detection)

    case harness.run(prompt, path, adapter_opts) do
      {:ok, result} when is_map(result) ->
        result |> proposal_payload() |> decode_predicates() |> loadable_predicates()

      _ ->
        []
    end
  end

  # T8.7 (ADR-0016): pick the enrichment harness. An explicitly injected `:harness`
  # MODULE (the test seam) is used as-is; otherwise the default is RESOLVED via
  # `Kazi.Harness.resolve/1` so app config can select opencode for enrichment too.
  # On a resolve error the legacy `@default_harness` stands (no behaviour change).
  defp resolve_harness(opts) do
    case Keyword.get(opts, :harness) do
      nil ->
        case Kazi.Harness.resolve(model: Keyword.get(opts, :model)) do
          {:ok, {module, harness_opts}} -> {module, harness_opts}
          {:error, _reason} -> {@default_harness, []}
        end

      module ->
        {module, []}
    end
  end

  @doc """
  Builds the prompt asking the harness to propose live predicates for an adopted
  repo whose stack `detection` is already known (ADR-0013 §4).

  Pure and total. It instructs the harness to emit a single JSON object listing
  `http_probe`/`browser` predicates derived from the repo's discovered endpoints —
  checkable live criteria, not prose — leaving the deterministic `test_runner`
  predicate to detection.
  """
  @spec enrich_prompt(detection()) :: String.t()
  def enrich_prompt(detection) when is_map(detection) do
    stack = detection |> Map.get(:stack, :unknown) |> to_string()

    """
    This repository's stack was detected as #{stack} and its test command is
    already captured. Inspect the repository for LIVE, externally-observable
    surfaces — HTTP endpoints it serves and user-facing pages — and propose kazi
    live predicates that check them.

    Respond with a SINGLE JSON object and nothing else, of the shape:

      {
        "predicates": [
          {"id": "<stable_id>", "provider": "http_probe",
           "description": "<what must become true>",
           "url": "<full URL>", "expect_status": 200}
        ]
      }

    Each predicate's "provider" MUST be one of: #{Enum.join(@enrich_providers, ", ")}.
    Do NOT propose a test_runner predicate — detection already owns that. Any other
    key on a predicate is passed verbatim to the live provider as its config.
    Propose only predicates you can ground in a real endpoint you found; if none,
    return {"predicates": []}.
    """
  end

  # The proposal payload out of the harness result map, mirroring Kazi.Authoring:
  # a pre-decoded map under `:proposal`/`:result` is used directly; otherwise the
  # `:result` text (the agent's final result in a `claude --output-format json`
  # envelope) is the JSON to decode; falls back to raw `:output`.
  defp proposal_payload(%{proposal: %{} = proposal}), do: proposal
  defp proposal_payload(%{result: %{} = result}), do: result
  defp proposal_payload(%{result: result}) when is_binary(result), do: result
  defp proposal_payload(%{output: output}) when is_binary(output), do: output
  defp proposal_payload(_result), do: nil

  # Decode the proposal into the raw `"predicates"` list. A JSON string decodes to
  # its object; an already-decoded map passes through; anything else yields `[]`.
  defp decode_predicates(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = map} -> decode_predicates(map)
      _ -> []
    end
  end

  defp decode_predicates(%{"predicates" => list}) when is_list(list), do: list
  defp decode_predicates(_payload), do: []

  # Keep only proposed predicates that are (a) a live provider enrichment may
  # propose and (b) loadable-shaped: each candidate is normalised to a goal-file
  # predicate map and accepted only if it round-trips through
  # `Kazi.Goal.Loader.from_map/1`. So enrichment can only ever add predicates a
  # goal-file could load — a malformed or non-live entry is silently dropped.
  defp loadable_predicates(list) do
    list
    |> Enum.map(&normalize_predicate/1)
    |> Enum.filter(&loadable?/1)
  end

  # Normalise a raw proposal entry to a string-keyed goal-file predicate map: a
  # required string `id` and a live `provider`, every other key carried verbatim
  # as sibling config (the loader collects non-reserved keys into config). A
  # missing id, a non-string provider, or a non-live provider yields `nil`.
  defp normalize_predicate(%{"id" => id, "provider" => provider} = raw)
       when is_binary(id) and id != "" and is_binary(provider) do
    if provider in @enrich_providers do
      raw
      |> stringify_keys()
      |> Map.put("id", id)
      |> Map.put("provider", provider)
    else
      nil
    end
  end

  defp normalize_predicate(_raw), do: nil

  # A candidate is loadable iff it round-trips through the same validated loader
  # the CLI uses — wrapped in a minimal one-predicate goal map so a single
  # predicate is validated in isolation.
  defp loadable?(nil), do: false

  defp loadable?(%{} = predicate) do
    case Kazi.Goal.Loader.from_map(%{"id" => "adopt-enrich", "predicate" => [predicate]}) do
      {:ok, _goal} -> true
      {:error, _reason} -> false
    end
  end

  # Stringify map keys for the goal-file predicate shape (a stub may hand back
  # atom-keyed config; the loader re-atomises non-reserved keys).
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # A goal-file predicate MAP in the shape Kazi.Goal.Loader.from_map/1 accepts:
  # string keys, `provider: "test_runner"` (-> :tests kind), `:cmd`/`:args` spread
  # as sibling keys the loader collects into the predicate's `config`. So a
  # detected predicate round-trips through the same validated loader the CLI uses.
  defp predicate_map(cmd, args) do
    %{
      "id" => @predicate_id,
      "provider" => "test_runner",
      "description" => "project test suite passes",
      "cmd" => cmd,
      "args" => args
    }
  end

  # Marker → {cmd, args}. Go/Elixir/Python are fixed; Node derives from the
  # package.json `test` script (and is no-detection without a usable one).
  defp command_for(_reader, _path, "go.mod"), do: {:ok, "go", ["test", "./..."]}
  defp command_for(_reader, _path, "mix.exs"), do: {:ok, "mix", ["test"]}
  defp command_for(_reader, _path, "pyproject.toml"), do: {:ok, "pytest", []}
  defp command_for(_reader, _path, "setup.cfg"), do: {:ok, "pytest", []}

  defp command_for(reader, path, "package.json") do
    # We require that a REAL `scripts.test` exists, then run it via `npm test`.
    # The script body is not re-shelled directly (that would couple kazi to the
    # project's runner versioning); `npm test` runs whatever `scripts.test` is —
    # exactly what a developer runs.
    with {:ok, contents} <- read(reader, path, "package.json"),
         {:ok, %{} = json} <- decode_json(contents),
         :ok <- usable_test_script(json) do
      {:ok, "npm", ["test"]}
    else
      _ -> :no
    end
  end

  # :ok when package.json declares a real `scripts.test`; :no when it is absent,
  # blank, or the `npm init` placeholder that exits non-zero on purpose (emitting
  # a predicate for it would yield a command that can never pass).
  defp usable_test_script(%{"scripts" => %{"test" => script}})
       when is_binary(script) and script != "" do
    if String.contains?(script, "no test specified"), do: :no, else: :ok
  end

  defp usable_test_script(_json), do: :no

  # Dispatch the filesystem seam: a bare module follows the `File` contract
  # (`regular?/1`, `read/1`); a `{module, state}` tuple threads its state through
  # `regular?/2`/`read/2` so a stateful in-memory reader is injectable in tests.
  defp present?({mod, state}, path, marker), do: mod.regular?(state, Path.join(path, marker))
  defp present?(mod, path, marker), do: mod.regular?(Path.join(path, marker))

  defp read({mod, state}, path, marker), do: mod.read(state, Path.join(path, marker))
  defp read(mod, path, marker), do: mod.read(Path.join(path, marker))

  defp decode_json(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :no
    end
  end
end
