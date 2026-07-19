defmodule Kazi.Harness.Profile do
  @moduledoc """
  A **harness profile**: the data description of one CLI coding harness so kazi can
  drive it through the generic `Kazi.Harness.CliAdapter` (T8.2) without a bespoke
  adapter module per harness (ADR-0016).

  Different harnesses diverge at exactly two points of the subprocess boundary:

    * **how the argv is assembled** — `claude -p <prompt> --output-format json …`
      vs `opencode run <prompt> --model <m> --format json`; and
    * **how stdout is parsed** — Claude emits a single JSON envelope, opencode a
      stream of NDJSON events. Everything else (run in the workspace with `cd:`,
      capture exit + output, ADR-0008) is shared.

  A profile captures those two divergent points as function fields plus the
  default `command` and the set of optional opt keys the harness understands:

    * `:id` — the stable atom id (`:claude`, `:opencode`, …).
    * `:command` — the default binary name. The CliAdapter still lets a caller
      override it per-run via a `:command` opt (the test-stub seam); this is the
      fallback when none is given.
    * `:build_args` — `(prompt, opts) -> [arg]`, a PURE function rendering the
      subprocess args (everything after the command itself). Deterministic: the
      same `(prompt, opts)` always renders the same argv.
    * `:parse` — `(output) -> map()`, a PURE, ADDITIVE parser turning the
      harness's stdout into the structured subset of the result map
      (`:result`, `:tokens`, `:cost_usd`, `:touched`, `:cost`). It returns ONLY
      the fields it can extract; the CliAdapter merges this over the always-present
      base (`output`/`exit`/`command`/`workspace`), so a harness that reports
      nothing structured degrades cleanly to the base map (ADR-0008: the budget's
      token dimension then falls back to an estimate).
    * `:supported_opts` — the optional opt keys this harness accepts (e.g. Claude's
      `:max_budget_usd`/`:allowed_tools`/`:permission_mode`). Lets the resolution
      seam (T8.5) drop opts a harness does not understand instead of passing a
      Claude-only flag to opencode.
    * `:prompt_via` — how the prompt reaches the harness: `:argv` (the default —
      the prompt is one of the args `build_args` renders, exactly as
      Claude/opencode/Codex do) or `:file` (the CliAdapter writes the prompt to a
      TEMP FILE and threads its path to `build_args` as `opts[:prompt_file]`;
      `build_args` references that path instead of embedding the prompt text).
      `:file` exists for the Antigravity non-TTY workaround (ADR-0022, T14.3,
      `google-antigravity/antigravity-cli#76`): invoking `run --prompt-file <tmp>
      --output json --yes` sidesteps the bug where the bare `--prompt`/`-p` flag
      silently DROPS stdout under a non-TTY (pipe/subprocess) — exactly kazi's
      mode. `build_args` STAYS PURE either way: the adapter owns the temp-file IO
      and lifecycle; the profile only reads the path the adapter materialized.

  Profiles are values, so a built-in profile (`Kazi.Harness.Registry`) and a
  config-declared custom profile (T8.5) share one shape; the latter references a
  built-in parser by name rather than carrying its own closure.
  """

  @typedoc "A pure argv renderer: the args AFTER the command (deterministic)."
  @type build_args :: (prompt :: String.t(), opts :: keyword() -> [String.t()])

  @typedoc "A pure, additive stdout parser: the structured subset of the result map."
  @type parse :: (output :: String.t() -> map())

  @typedoc "How the prompt reaches the harness: an argv arg (default) or a temp file."
  @type prompt_via :: :argv | :file

  @type t :: %__MODULE__{
          id: atom(),
          command: String.t(),
          build_args: build_args(),
          parse: parse(),
          supported_opts: [atom()],
          prompt_via: prompt_via()
        }

  @enforce_keys [:id, :command, :build_args, :parse]
  defstruct id: nil,
            command: nil,
            build_args: nil,
            parse: nil,
            supported_opts: [],
            prompt_via: :argv

  @doc """
  Renders the subprocess args (everything after the command) for `prompt`/`opts`
  by applying the profile's `:build_args`. Pure and deterministic.
  """
  @spec build_args(t(), String.t(), keyword()) :: [String.t()]
  def build_args(%__MODULE__{build_args: builder}, prompt, opts)
      when is_binary(prompt) and is_list(opts) do
    builder.(prompt, opts)
  end

  @doc """
  Parses the harness `output` into the structured subset of the result map by
  applying the profile's `:parse`. Pure and additive — returns only the fields the
  harness reported (possibly `%{}`).
  """
  @spec parse(t(), String.t()) :: map()
  def parse(%__MODULE__{parse: parser}, output) when is_binary(output) do
    parser.(output)
  end
end
