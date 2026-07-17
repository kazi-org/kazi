defmodule Kazi.TeachCoherenceReverseTest do
  @moduledoc """
  Issue #973: the REVERSE direction of the T16.4 doc<->CLI coherence guard.

  `Kazi.TeachCoherenceTest` only catches FABRICATED doc references — a
  command/flag named in SKILL.md/AGENTS.md that doesn't exist in the real CLI.
  It never asserts the reverse: that every real, shipped `apply` flag is
  documented SOMEWHERE in the agent-facing teach surface (SKILL.md + AGENTS.md
  combined). That gap let `--allow-primary-workspace`/`--allow-duplicate-run`
  ship with zero doc coverage (issue #937) until a human noticed by hand.

  The authoritative flag source is the same `kazi help --json` surface the
  forward guard uses (T16.1) — generated from `Kazi.CLI`'s `@commands` /
  `@switches` / `@flag_docs`, so this can never drift from the real parser.

  Not every real flag belongs in the introductory teach surface — SKILL.md and
  AGENTS.md are an onboarding on-ramp (the primary `plan`/`apply`/`status`/
  `adopt` recipes), not an exhaustive flag reference; comprehensive flag docs
  live in `kazi help --json`, README.md, and docs/. So a flag that IS covered
  elsewhere, or is genuinely advanced/internal, may be named on the
  `@undocumented_flags_allowlist` below — but only with a comment saying why,
  so a newly-added flag can never silently skip documentation everywhere.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # The real `apply` flags (literal `--flag` strings), straight from `kazi help
  # --json`'s `apply` command entry — never a hand-maintained copy.
  defp apply_flags do
    out = capture_io(fn -> assert Kazi.CLI.run(["help", "--json"]) == 0 end)
    {:ok, payload} = Jason.decode(String.trim(out))

    payload["commands"]
    |> Enum.find(&(&1["name"] == "apply"))
    |> Map.fetch!("flags")
    |> Enum.map(& &1["name"])
  end

  # The combined agent-facing teach surface: the rendered SKILL.md plus the root
  # AGENTS.md (read off disk, same as the forward guard).
  defp combined_docs do
    Kazi.Teach.InstallSkill.skill_md() <> "\n" <> File.read!("AGENTS.md")
  end

  # Real `apply` flags that are NOT (yet) mentioned in SKILL.md/AGENTS.md, each
  # with the reason it is exempt from the reverse guard below. Keep this list
  # short and reviewed — every entry is a conscious decision, not a silent gap.
  @undocumented_flags_allowlist %{
    "--env" =>
      "deploy-environment selector; documented in README.md, not the intro teach surface",
    "--debrief" =>
      "opt-in economy debrief capture (ADR-0058); an advanced instrumentation flag, not part of the intro recipes",
    "--effort" =>
      "claude harness reasoning-effort override; documented in docs/orchestrator-recipe.md and ADR-0047",
    "--permission-mode" =>
      "claude harness permission-mode override; documented in README.md and ADR-0016",
    "--allowed-tools" =>
      "claude harness tool allow-list override; documented in ADR-0016 and ADR-0047",
    "--context-store" =>
      "opt-in context-store integration (ADR-0045); documented in docs/context-store.md",
    "--context-budget" =>
      "paired with --context-store (ADR-0045); documented in docs/context-store.md",
    "--session-name" =>
      "run-labeling flag; documented in docs/dashboard.md and docs/orchestrator-recipe.md",
    "--no-preflight" =>
      "base-dispatchability preflight escape (T44.9); an advanced safety flag documented in docs/orchestrator-recipe.md and `kazi help`, not part of the intro recipes"
  }

  describe "every real `apply` flag is documented somewhere (the reverse guard, issue #973)" do
    test "each apply flag is either in SKILL.md+AGENTS.md or on the reviewed allow-list" do
      docs = combined_docs()

      undocumented =
        apply_flags()
        |> Enum.reject(&String.contains?(docs, &1))
        |> Enum.reject(&Map.has_key?(@undocumented_flags_allowlist, &1))

      assert undocumented == [],
             "apply flag(s) #{inspect(undocumented)} are referenced by neither " <>
               "SKILL.md/AGENTS.md nor `@undocumented_flags_allowlist` — a real, " <>
               "shipped flag must be documented somewhere or explicitly allow-listed " <>
               "with a reason (issue #973)"
    end

    test "every allow-listed flag is still a REAL apply flag (no stale entries)" do
      flags = apply_flags()

      stale =
        @undocumented_flags_allowlist
        |> Map.keys()
        |> Enum.reject(&(&1 in flags))

      assert stale == [],
             "`@undocumented_flags_allowlist` names flag(s) #{inspect(stale)} that are " <>
               "no longer real `apply` flags — remove the stale entry"
    end
  end

  describe "the reverse guard is load-bearing (an undocumented real flag fails)" do
    test "removing a documented flag's every mention makes the guard fail" do
      # `--allow-primary-workspace` is a real apply flag documented in SKILL.md +
      # AGENTS.md today. Strip every mention from a test-local COPY of the docs
      # (never the real files) and confirm the guard would have caught it — this
      # is exactly the historical gap (issue #937) the guard now prevents.
      tampered = String.replace(combined_docs(), "--allow-primary-workspace", "")

      undocumented =
        apply_flags()
        |> Enum.reject(&String.contains?(tampered, &1))
        |> Enum.reject(&Map.has_key?(@undocumented_flags_allowlist, &1))

      assert "--allow-primary-workspace" in undocumented,
             "stripping every mention of --allow-primary-workspace should make the " <>
               "reverse guard flag it as undocumented"
    end
  end
end
