# Add your own CLI coding harness

A contributor recipe. Adding a new CLI coding harness to kazi is **profile DATA,
not a code change** -- no new adapter module, no edit to the loop. You author a
profile (a `command`, an argv renderer, a stdout parser), register it, and prove
it with three small tests. That is the whole job.

This recipe is exactly how `:codex` (T14.2), `:antigravity` (T14.3), and `:claw`
(T14.4) were added. It rests on two frozen decisions, read them first:

- [ADR-0016](adr/0016-generic-harness-profiles.md) -- a harness is a
  `Kazi.Harness.Profile` value driven by one generic `Kazi.Harness.CliAdapter`.
- [ADR-0022](adr/0022-harness-onboarding-conformance.md) -- the conformance
  contract a profile must meet, and this recipe.

The whole machinery lives in `lib/kazi/harness/`. Skim
[`profile.ex`](../lib/kazi/harness/profile.ex) (the struct) and
[`cli_adapter.ex`](../lib/kazi/harness/cli_adapter.ex) (the one adapter that runs
every profile) so you know what the adapter already does for you: it runs
`System.cmd` in the workspace, captures `output`/`exit`, and ALWAYS provides the
base result map. Your parser only adds to it.

Every dispatch is also automatically tied to the controller's lifetime (issue
#857, [`child_supervisor.ex`](../lib/kazi/harness/child_supervisor.ex)): the
adapter wraps your harness's command so it cannot outlive a crashed/killed kazi
process, and reports the harness subprocess's own OS pid as `:harness_pid` on
the result map. This is transparent -- no profile opts into or configures it.

## The conformance contract (ADR-0022)

kazi drives every harness as a **non-interactive subprocess with no TTY** and
parses its stdout. A harness is **first-class** only when it:

1. runs non-interactively from a single prompt;
2. emits machine-parseable output (JSON/JSONL preferred) to stdout; and
3. does so CORRECTLY under a non-TTY subprocess (a pipe / redirect) -- this is the
   one that bites: some tools behave differently when stdout is not a terminal.

Support is **tiered** by how well a tool meets that bar (ADR-0022, decision 3):

- **Fully-conformant** -- clean structured stdout under a non-TTY. Template:
  [`profiles/codex.ex`](../lib/kazi/harness/profiles/codex.ex).
- **Conformant with a workaround** -- meets the bar only via a documented seam.
  Example: [`profiles/antigravity.ex`](../lib/kazi/harness/profiles/antigravity.ex)
  (the non-TTY-stdout bug, handled with `prompt_via: :file`).
- **Best-effort / demo-grade** -- emits no structured output; kazi surfaces raw
  stdout with no cost/token extraction, clearly labelled. Example:
  [`profiles/claw.ex`](../lib/kazi/harness/profiles/claw.ex).

If a tool cannot meet the contract, add it best-effort with honest labelling --
never scrape unstructured stdout and pretend it is structured.

## Step 1 -- Author the profile

A profile diverges from every other harness at exactly two points: how the argv
is assembled, and how stdout is parsed. Put those two PURE functions in
`lib/kazi/harness/profiles/<id>.ex` (the existing `:codex`, `:antigravity`,
`:claw` profiles each have their own file; small profiles may also live as a
`defp <id>` directly in `Kazi.Harness.Registry`).

```elixir
defmodule Kazi.Harness.Profiles.Mytool do
  @doc "Renders the args AFTER the `mytool` command (pure, deterministic)."
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) when is_binary(prompt) and is_list(opts) do
    ["run", prompt, "--json"] ++ model_args(opts)
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" -> ["--model", m]
      _ -> []
    end
  end

  @doc "Parses stdout into the ADDITIVE subset of the result map (pure, total)."
  @spec parse(String.t()) :: map()
  def parse(output) when is_binary(output) do
    # decode, extract only what you can; %{} when there is nothing structured.
  end
end
```

Two rules the conformance helper and the adapter both depend on:

- **`build_args/2` is pure argv.** Deterministic: the same `(prompt, opts)` always
  renders the same args (everything AFTER the command). No IO. Append optional
  flags ONLY when the opt is present, so a no-model run renders the bare form --
  see `codex.ex`'s `model_args/1`.
- **`parse/1` is pure and ADDITIVE.** Return ONLY the fields you can extract
  (`:result`, `:tokens`, `:cost`, `:cost_usd`, `:touched`). The adapter merges
  your map over the always-present base (`:output`/`:exit`/`:command`/
  `:workspace`), so a tool that reports nothing structured degrades cleanly: empty
  or malformed output MUST yield `%{}` and never crash. Do not fabricate token
  counts -- an absent `:tokens` lets the budget fall back to an estimate
  (ADR-0008).

### The non-TTY workaround seam (`prompt_via`)

Most harnesses take the prompt as an argv argument -- that is the default,
`prompt_via: :argv`. If a tool drops or mangles stdout when the prompt is passed
on the argv under a non-TTY (the load-bearing failure ADR-0022 names), set
`prompt_via: :file` on the profile. The `CliAdapter` then writes the prompt to a
temp file in the workspace, threads its path to `build_args` as
`opts[:prompt_file]`, and deletes it afterwards -- so `build_args` STAYS PURE and
only references the path the adapter materialized.

This is exactly the Antigravity case: bug `antigravity-cli#76` silently drops
stdout under a pipe, so `antigravity.ex` ignores the `prompt` argument and renders
`run --prompt-file <tmp> --output json --yes`, reading `opts[:prompt_file]`. See
`profiles/antigravity.ex` and the `materialize_prompt/4` logic in
`cli_adapter.ex`.

## Step 2 -- Register it

Wire the profile into [`Kazi.Harness.Registry`](../lib/kazi/harness/registry.ex)
at three points (this is the entire registration; the resolution seam and CLI flag
pick it up for free):

1. A `defp <id>` that returns the `%Profile{}` -- point `:build_args`/`:parse` at
   your module's functions, set `:supported_opts` to the opts the tool actually
   understands, and set `prompt_via: :file` if you need the workaround:

   ```elixir
   defp mytool do
     %Profile{
       id: :mytool,
       command: "mytool",
       build_args: &Profiles.Mytool.build_args/2,
       parse: &Profiles.Mytool.parse/1,
       supported_opts: [:command, :model]
     }
   end
   ```

2. A `fetch/1` clause: `def fetch(:mytool), do: {:ok, mytool()}`.
3. Add `:mytool` to `ids/0`.

`:supported_opts` is what lets the resolution seam drop opts a harness does not
understand (e.g. `:claw` lists only `[:command]` because claw has no model flag).
Auth (API keys) is NOT a profile concern -- the operator supplies it via the
environment, forwarded through `opts[:env]`.

## Step 3 -- Add the three tests

Every profile proves itself the same way (ADR-0022, decision 2), using the uniform
helper [`Kazi.Harness.Conformance`](../test/support/harness_conformance.ex) (T14.1).

1. **A `build_args` unit test** -- the exact non-interactive argv your tool will be
   exec'd with, including the no-model case (the optional flag is absent).

2. **A golden-transcript `parse` test** -- record a sample of the tool's REAL
   stdout, check it in under `test/fixtures/harness/<id>_*`, and assert `parse`
   extracts the right subset. Both the argv and the parse assertion go through one
   `assert_profile_conformance/2` call (see existing cases in
   [`test/kazi/harness/conformance_test.exs`](../test/kazi/harness/conformance_test.exs)):

   ```elixir
   assert_profile_conformance(:mytool,
     prompt: "fix the failing test",
     opts: [model: "some-model"],
     expected_argv: ["run", "fix the failing test", "--json", "--model", "some-model"],
     transcript: "harness/mytool_run.jsonl",
     expected_parse: %{result: "Made the failing unit test pass.", tokens: 2400, cost: %{tokens: 2400}}
   )
   ```

   `expected_parse` is asserted as a STRICT SUBSET: every declared field must be
   present and equal, and NO unvetted structured field may sneak in. For a
   best-effort tool, declare only `%{result: "..."}` -- see the `:claw` cases.

3. **A live smoke, tagged `:<id>_live`** -- a non-hermetic test that drives the
   REAL binary with real creds. Tag it `@moduletag :<id>_live` and add that tag to
   the `exclude:` list in [`test/test_helper.exs`](../test/test_helper.exs) so the
   standard `mix test` and CI stay hermetic. The test must PROBE its dependencies
   (binary on PATH + auth) and SKIP HONESTLY when they are absent -- never fail,
   never fake-pass. Copy [`test/kazi/codex_live_test.exs`](../test/kazi/codex_live_test.exs)
   and adapt the binary/auth probe. Run it explicitly:

   ```sh
   mix test --only mytool_live test/kazi/mytool_live_test.exs
   ```

## Step 4 -- Update the canonical harness list

The harness list is one shared canonical string, drift-checked in CI (T9.9). Add
your id in the SAME change, in both places, or CI goes red (ADR-0022, decision 4):

- `site/src/canonical.mjs` -- append your id to the `HARNESSES` array.
- `README.md` -- add a row to the **Tiered harness support** table stating the
  tool's tier and notes (T14.5).

## Done

That is the bounded, repeatable recipe: one profile, three tests, one
canonical-string update -- no architecture change. Cross-check your work against
the worked examples:

- `profiles/codex.ex` -- fully-conformant template (JSONL stream parse).
- `profiles/antigravity.ex` -- conformant with the `prompt_via: :file` non-TTY
  workaround.
- `profiles/claw.ex` -- best-effort / demo-grade (raw stdout as `:result`).
