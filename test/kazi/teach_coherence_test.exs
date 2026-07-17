defmodule Kazi.TeachCoherenceTest do
  @moduledoc """
  T16.4 (ADR-0024): the SKILL.md / AGENTS.md <-> CLI coherence guard — the drift
  test (mirroring the T9.9 README<->site check).

  ADR-0024 names the drift risk explicitly: "the SKILL / `AGENTS.md` can fall out
  of sync with the real CLI; a coherence test must assert they reference only real
  commands/flags (the same guard pattern as the README<->site check, T9.9)".

  This test makes that guarantee load-bearing. The authoritative command/flag
  surface is `kazi help --json` (T16.1) — which is GENERATED from the `@commands`
  / `@switches` / `@flag_docs` data in `Kazi.CLI`, so the real command table IS
  the source of truth. We then:

    * extract every `` `kazi <command>` `` reference (and every `--flag`) from the
      rendered SKILL.md (`Kazi.Teach.InstallSkill.skill_md/0`) and from the root
      `AGENTS.md` (read off disk via `File.read!/1`), and
    * assert each referenced command is in the real command table and each
      referenced flag is a real switch.

  A command or flag named in the skill or AGENTS.md but ABSENT from the real CLI
  FAILS the test — the CI guard against doc drift. The final tests prove the guard
  is load-bearing: a deliberately-introduced fake command/flag in a test-local
  copy of the doc is caught.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # ===========================================================================
  # The authoritative CLI surface — from `kazi help --json` (T16.1).
  #
  # `help --json` is generated from `Kazi.CLI`'s `@commands` / `@switches` /
  # `@flag_docs` (the parser's own tables), so this is the REAL command/flag set
  # the parser recognizes — never a hand-maintained copy.
  # ===========================================================================

  # The full surface decoded once: %{commands: MapSet, flags: MapSet}. The flag
  # set is the UNION of every command's flags, plus the top-level help/version
  # flags (and their aliases) the help surface advertises, so a flag referenced
  # anywhere in the docs resolves against the same set the CLI accepts.
  defp cli_surface do
    out = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end)
    {:ok, payload} = Jason.decode(String.trim(out))

    commands =
      payload["commands"]
      |> Enum.map(& &1["name"])
      |> MapSet.new()

    flags =
      payload["commands"]
      |> Enum.flat_map(fn cmd -> Enum.map(cmd["flags"], & &1["name"]) end)
      |> MapSet.new()
      # --help/-h and --version/-v are real, parser-recognized switches that the
      # docs legitimately reference but that the per-command flag lists omit (they
      # are global). Include them so a real flag is never a false drift positive.
      |> MapSet.union(MapSet.new(["--help", "--version"]))

    %{commands: commands, flags: flags}
  end

  # ===========================================================================
  # Extraction — pull `kazi <command>` and `--flag` references out of a doc.
  #
  # A `kazi <command>` reference is a CODE token, not prose. The docs say "kazi
  # drives a harness" / "kazi sits in the middle" in narrative — those are NOT
  # command references. So we extract command/flag references ONLY from CODE
  # contexts: inline backtick spans (`` `kazi propose --json` ``) and fenced code
  # blocks (```sh … ```). This is exactly how an agent would read a command out of
  # the doc, and it is what keeps the guard from flagging the prose word "kazi".
  # ===========================================================================

  # Pull every code context out of the markdown: each fenced block's body and each
  # inline backtick span. Returns a list of code strings to scan for references.
  @fenced ~r/```[a-z]*\n(.*?)```/s
  @inline ~r/`([^`\n]+)`/

  defp code_contexts(doc) do
    fenced = Regex.scan(@fenced, doc) |> Enum.map(fn [_full, body] -> body end)
    inline = Regex.scan(@inline, doc) |> Enum.map(fn [_full, body] -> body end)
    fenced ++ inline
  end

  # Every command word that follows `kazi ` when `kazi` BEGINS the invocation —
  # i.e. it is the first token on a (code) line, optionally after shell lead-in
  # like a pipe (`… | kazi …`) or command substitution (`$(kazi …`). This is how a
  # real `kazi` command is written; it excludes mid-sentence prose such as the
  # architecture diagram's "drive kazi as a tool" (kazi appears mid-line there).
  # We keep only tokens shaped like a real command name (lowercased letters /
  # hyphens), so argument placeholders (`kazi <goal-file>`) and the bare `kazi`
  # heading never match — they are arguments, not commands.
  @command_ref ~r/(?:^|\||\$\()\s*kazi\s+([a-z][a-z-]+)/m

  defp referenced_commands(doc) do
    doc
    |> code_contexts()
    |> Enum.flat_map(fn ctx ->
      @command_ref
      |> Regex.scan(ctx)
      |> Enum.map(fn [_full, cmd] -> cmd end)
    end)
    |> Enum.uniq()
  end

  # Every long flag (`--flag`) mentioned in a code context. The docs reference
  # flags both in narrative-with-backticks ("Other propose flags: `--workspace`…")
  # and in fenced example commands; both are code contexts. We capture only
  # `[a-z-]` after the `--`, so a placeholder like `--out <path>` yields `--out`
  # and a value like `--no-json` reduces to its canonical form.
  @flag_ref ~r/(--[a-z][a-z-]+)/

  defp referenced_flags(doc) do
    doc
    |> code_contexts()
    |> Enum.flat_map(fn ctx ->
      @flag_ref
      |> Regex.scan(ctx)
      |> Enum.map(fn [_full, flag] -> flag end)
    end)
    |> Enum.uniq()
  end

  # T42.3 (ADR-0052): the PROSE of the doc — everything OUTSIDE a code context.
  # The inverse of `code_contexts/1`: fenced blocks and inline spans are blanked,
  # leaving the narrative a reader actually acts on.
  #
  # Why prose only: a slash-command reference is written in narrative ("fall back
  # to /plan"), whereas the legitimate slashes in these docs live in EXAMPLES —
  # the worked example's `/healthz` HTTP endpoint appears 3x in each doc, inside a
  # JSON block and a shell invocation. Scanning the whole doc would flag
  # `/healthz`, and a guard that cries wolf gets deleted.
  defp prose(doc) do
    doc
    |> String.replace(@fenced, " ")
    |> String.replace(@inline, " ")
  end

  # T42.3: a SLASH-COMMAND token in prose — a personal-skill reference like
  # `/plan` or `/foo`.
  #
  # The lookbehind is the whole design. `/` must NOT be preceded by a word char,
  # another `/`, or `:` — which excludes, with no allowlist to maintain:
  #   * paths          — `docs/plans/E42.md`, `git/worktree/scratch`
  #   * URLs           — `https://github.com/...`
  #   * prose slashes  — `and/or`, `input/output`, `loop/qualify`
  # and keeps exactly what a slash command looks like: a `/word` opening a token.
  #
  # Known gap (found while doing T42.1, recorded rather than silently tolerated):
  # this does NOT catch `loop/qualify`. The `/` there is a separator, so the form
  # still NAMES external skills and still violates ADR-0052, but no regex can tell
  # it from `and/or` without guessing. That one is caught by review, not CI.
  @slash_token ~r{(?<![\w/:])/([a-z][a-z-]*)}

  defp referenced_slash_tokens(doc) do
    @slash_token
    |> Regex.scan(prose(doc))
    |> Enum.map(fn [_full, tok] -> tok end)
    |> Enum.uniq()
  end

  # ===========================================================================
  # The guard core — assert every referenced command/flag is real.
  # ===========================================================================

  # Assert each `kazi <command>` reference in `doc` is a real CLI command, and
  # each `--flag` is a real CLI switch. The error names the offending token and
  # the surface it came from, so a CI failure reads as a drift report.
  defp assert_coherent(doc, surface, label) do
    bad_commands =
      doc
      |> referenced_commands()
      |> Enum.reject(&MapSet.member?(surface.commands, &1))

    assert bad_commands == [],
           "#{label} references command(s) not in the real CLI table " <>
             "(kazi help --json): #{inspect(bad_commands)}. " <>
             "Real commands: #{surface.commands |> MapSet.to_list() |> Enum.sort() |> inspect()}"

    bad_flags =
      doc
      |> referenced_flags()
      |> Enum.reject(&MapSet.member?(surface.flags, &1))

    assert bad_flags == [],
           "#{label} references flag(s) not in the real CLI switches " <>
             "(kazi help --json): #{inspect(bad_flags)}. " <>
             "Real flags: #{surface.flags |> MapSet.to_list() |> Enum.sort() |> inspect()}"

    # T42.3 (ADR-0052 decision 1): ANY `/<word>` token in PROSE is a slash-command
    # reference — the operator's personal skill library assumed universal. A reader
    # without `/plan` installed cannot act on "fall back to /plan".
    #
    # DEVIATION from T42.3 as written, deliberate and flagged for review: the task
    # says to fail only on a token "that does not match a real kazi CLI verb". That
    # allowlist would PERMIT `/plan` — and `/plan` was the primary offender this
    # epic exists for (10 occurrences in install_skill.ex at E42's premise, beside
    # /tidy, /loop, /qualify). Implemented literally, the guard would miss the exact
    # regression it was written to catch.
    #
    # The allowlist rests on a false premise: kazi's CLI is invoked as `kazi plan`,
    # NEVER as `/plan`. The real form always sits in a code context, which `prose/1`
    # already strips. So no `/<word>` surviving into prose is ever a legitimate kazi
    # reference, and the sharper, correct rule is: none belong there.
    bad_slash = referenced_slash_tokens(doc)

    assert bad_slash == [],
           "#{label} references slash-command token(s) in prose: " <>
             "#{inspect(Enum.map(bad_slash, &"/#{&1}"))}. " <>
             "These name an external tool's skill as though it were universal " <>
             "(ADR-0052 decision 1) — a reader without it installed cannot act on the " <>
             "sentence. Describe the CONTRACT instead (e.g. \"your own planning " <>
             "workflow\"), or use the real CLI form (`kazi plan`, in backticks). " <>
             "kazi is never invoked as `/verb`, so no slash token belongs in prose."
  end

  # ===========================================================================
  # The live guard — both surfaces must reference only real commands/flags.
  # ===========================================================================

  describe "doc <-> CLI coherence (the drift guard)" do
    test "the rendered SKILL.md references only real commands and flags" do
      assert_coherent(Kazi.Teach.InstallSkill.skill_md(), cli_surface(), "SKILL.md")
    end

    test "the rendered AUTHORING.md references only real commands and flags" do
      # ADR-0074: the skill ships as three files; every rendered document is
      # held to the same drift guard as the SKILL.md router.
      assert_coherent(Kazi.Teach.InstallSkill.authoring_md(), cli_surface(), "AUTHORING.md")
    end

    test "the rendered RECIPES.md references only real commands and flags" do
      assert_coherent(Kazi.Teach.InstallSkill.recipes_md(), cli_surface(), "RECIPES.md")
    end

    test "the root AGENTS.md references only real commands and flags" do
      # Read AGENTS.md off disk (ADR-0024 decision 3: it ships in the repo root).
      # `File.read!/1` resolves against the project root (the test runner's cwd),
      # so this is the same file shipped to target repos.
      agents_md = File.read!("AGENTS.md")
      assert_coherent(agents_md, cli_surface(), "AGENTS.md")
    end

    test "the SKILL.md router references the primary recipe commands (sanity)" do
      # Guard against a regex that silently matches NOTHING (a guard asserting an
      # empty set is vacuously true). After ADR-0032 the primary verbs are
      # `plan`/`apply` (T26.1 router); the SKILL.md routes plan -> approve -> apply,
      # so confirm extraction found those primary commands.
      doc = Kazi.Teach.InstallSkill.skill_md()
      cmds = referenced_commands(doc)

      for required <- ["plan", "approve", "apply"] do
        assert required in cmds,
               "SKILL.md extraction did not find the `#{required}` command — " <>
                 "the regex may be broken (the guard would be vacuously green)"
      end
    end

    test "the root AGENTS.md references the primary recipe commands (sanity)" do
      # After T27.5 (ADR-0032) AGENTS.md teaches the PRIMARY verbs `plan`/`apply`
      # (run/propose are mentioned once as deprecated aliases, not as the path).
      # Assert extraction is non-vacuous on the primary verbs + the shared approve.
      doc = File.read!("AGENTS.md")
      cmds = referenced_commands(doc)

      for required <- ["plan", "approve", "apply"] do
        assert required in cmds,
               "AGENTS.md extraction did not find the `#{required}` command — " <>
                 "the regex may be broken (the guard would be vacuously green)"
      end
    end
  end

  # ===========================================================================
  # T26.5 (ADR-0031): every router sub-skill VERB maps to a REAL CLI command.
  #
  # ADR-0031's router fronts four human sub-skill verbs; ADR-0032 made three of
  # them identical to the CLI verb (plan/apply/status) and kept `adopt` as the one
  # human alias (-> `kazi init`). This map IS the E26 verb-map note: the SOLE place
  # a sub-skill verb may diverge from its CLI command. The guard below asserts each
  # mapped CLI command is REAL (in `kazi help --json`) and is actually referenced
  # by the rendered SKILL.md — so a sub-skill verb can never route to a command the
  # CLI does not ship, and the router can never silently drop a verb.
  # ===========================================================================

  @router_verb_to_cli %{
    "plan" => "plan",
    "apply" => "apply",
    "status" => "status",
    "adopt" => "init"
  }

  describe "router sub-skill verbs map to real CLI commands (T26.5)" do
    test "every router verb routes to a command in the real CLI table" do
      surface = cli_surface()

      for {verb, cli} <- @router_verb_to_cli do
        assert MapSet.member?(surface.commands, cli),
               "router verb `#{verb}` routes to `kazi #{cli}`, which is NOT a real CLI " <>
                 "command (kazi help --json): " <>
                 "#{surface.commands |> MapSet.to_list() |> Enum.sort() |> inspect()}"
      end
    end

    test "the rendered SKILL.md references each router verb's CLI command" do
      cmds = referenced_commands(Kazi.Teach.InstallSkill.skill_md())

      for {verb, cli} <- @router_verb_to_cli do
        assert cli in cmds,
               "SKILL.md does not reference `kazi #{cli}` — the `#{verb}` sub-skill " <>
                 "verb must route to a real, referenced CLI command (ADR-0031/0032)"
      end
    end
  end

  # ===========================================================================
  # The guard is LOAD-BEARING — a fake command / flag must FAIL.
  #
  # We splice a deliberately-bogus reference into a test-local COPY of each doc
  # (never the real file) and assert the guard rejects it. This proves the guard
  # catches drift rather than passing vacuously.
  # ===========================================================================

  describe "the guard is load-bearing (fake command/flag fails)" do
    test "a fake `kazi frobnicate` command is rejected" do
      tampered =
        Kazi.Teach.InstallSkill.skill_md() <>
          "\n\nDrift injected by the test: run `kazi frobnicate` to win.\n"

      assert_raise ExUnit.AssertionError, ~r/frobnicate/, fn ->
        assert_coherent(tampered, cli_surface(), "tampered SKILL.md")
      end
    end

    test "a fake `--turbo` flag is rejected" do
      tampered =
        File.read!("AGENTS.md") <>
          "\n\nDrift injected by the test: pass `--turbo` to go faster.\n"

      assert_raise ExUnit.AssertionError, ~r/--turbo/, fn ->
        assert_coherent(tampered, cli_surface(), "tampered AGENTS.md")
      end
    end

    test "the UNTAMPERED docs pass the very same guard (control)" do
      surface = cli_surface()
      # If these raised, the fake-command tests above would be meaningless.
      assert_coherent(Kazi.Teach.InstallSkill.skill_md(), surface, "SKILL.md")
      assert_coherent(File.read!("AGENTS.md"), surface, "AGENTS.md")
    end

    # T42.3 (ADR-0052): the regression this guard exists for. `/plan`, `/tidy`,
    # `/loop` and `/qualify` were REAL text in these docs — E42's whole premise —
    # naming the operator's personal skill library as though every reader had it.
    for tok <- ~w(foo plan tidy loop qualify) do
      test "an invented `/#{tok}` skill reference in prose is rejected" do
        tampered =
          Kazi.Teach.InstallSkill.skill_md() <>
            "\n\nDrift injected by the test: if kazi is unavailable, fall back to /#{unquote(tok)}.\n"

        assert_raise ExUnit.AssertionError, ~r{/#{unquote(tok)}}, fn ->
          assert_coherent(tampered, cli_surface(), "tampered SKILL.md")
        end
      end
    end

    test "an invented `/foo` in AGENTS.md prose is rejected" do
      tampered = File.read!("AGENTS.md") <> "\n\nWhen stuck, run /foo to sort it out.\n"

      assert_raise ExUnit.AssertionError, ~r{/foo}, fn ->
        assert_coherent(tampered, cli_surface(), "tampered AGENTS.md")
      end
    end

    # The false-positive guard. A guard that cries wolf gets deleted, so pin the
    # shapes that legitimately carry slashes and MUST stay silent: the worked
    # example's `/healthz` endpoint (already in both docs 3x), paths, URLs, and
    # prose separators.
    test "legitimate slashes in code contexts, paths and URLs do NOT trip the guard" do
      benign =
        Kazi.Teach.InstallSkill.skill_md() <>
          """

          A live probe example: `GET /healthz` returns 200, see docs/plans/E42.md
          and https://github.com/kazi-org/kazi for the write-up. Hygiene covers
          git/worktree/scratch sweeping, and the input/output split is unchanged.

          ```sh
          curl -sf http://localhost:4000/healthz
          ```
          """

      assert_coherent(benign, cli_surface(), "benign SKILL.md")
    end

    # The subtle one, and why this guard does NOT allowlist real kazi verbs.
    # `plan` IS a real verb, so T42.3's literal "fail only on tokens that are not
    # real kazi verbs" would PERMIT `/plan` — the primary offender. kazi is invoked
    # as `kazi plan`, never `/plan`, and the real form lives in a code context that
    # `prose/1` strips, so a `/plan` in prose is a personal-skill reference always.
    test "a slash token is rejected even when the word IS a real kazi verb" do
      surface = cli_surface()
      real = surface.commands |> MapSet.to_list() |> Enum.sort() |> List.first()

      tampered =
        Kazi.Teach.InstallSkill.skill_md() <>
          "\n\nWhen kazi is unavailable, fall back to /#{real}.\n"

      assert_raise ExUnit.AssertionError, ~r{/#{real}}, fn ->
        assert_coherent(tampered, surface, "SKILL.md with a real-verb slash token")
      end
    end

    # ...while the REAL CLI form stays legal, because it lives in a code context.
    test "the real `kazi <verb>` form in backticks is NOT flagged" do
      fine =
        Kazi.Teach.InstallSkill.skill_md() <>
          "\n\nAuthor the predicates with `kazi plan`, then converge with `kazi apply`.\n"

      assert_coherent(fine, cli_surface(), "SKILL.md with real CLI forms")
    end
  end
end
