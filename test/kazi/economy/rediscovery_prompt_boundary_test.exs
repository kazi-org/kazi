defmodule Kazi.Economy.RediscoveryPromptBoundaryTest do
  @moduledoc """
  T48.10 acc ("nothing in the dispatch prompt changes") / ADR-0058 decision 3
  ("report-only"): `Kazi.Economy.Rediscovery`'s output must feed NOTHING back
  into a dispatch. This pins the hard boundary structurally rather than by
  inference from behavior alone -- every module that builds a dispatch prompt
  or the context envelope threaded into one is grepped for a reference to the
  `Rediscovery` module, and none may have one.

  If a future change wires this report into the orientation pack / retrieval
  cache / harness prompt, this test fails LOUDLY at the exact boundary ADR-0058
  draws: a candidate may ship as a prompt/context change ONLY through the
  T48.12 benchmark gate, never by a direct read of this report.
  """
  use ExUnit.Case, async: true

  # Every module that assembles the dispatch prompt or the context envelope fed
  # into one (ADR-0009 thin-evidence-projection surface). Kept as an explicit
  # list (not a wildcard over lib/) so a new prompt-adjacent module is a
  # conscious addition to this guard, not a silent gap.
  @prompt_building_files [
    "lib/kazi/harness/prompt.ex",
    "lib/kazi/loop.ex",
    "lib/kazi/context/pack.ex",
    "lib/kazi/context/cache.ex",
    "lib/kazi/context/escalation.ex",
    "lib/kazi/context/stuck_bundle.ex",
    "lib/kazi/context/survey.ex",
    "lib/kazi/context/tier.ex",
    "lib/kazi/runtime.ex"
  ]

  test "no dispatch-prompt-building module references Kazi.Economy.Rediscovery" do
    root = Path.expand("../../..", __DIR__)

    offenders =
      for file <- @prompt_building_files,
          path = Path.join(root, file),
          File.exists?(path),
          source = File.read!(path),
          String.contains?(source, "Rediscovery"),
          do: file

    assert offenders == [],
           "prompt-building module(s) reference Kazi.Economy.Rediscovery, violating the " <>
             "report-only boundary (ADR-0058 decision 3): #{inspect(offenders)}"
  end

  test "every file in the guard list actually exists (the guard is not silently vacuous)" do
    root = Path.expand("../../..", __DIR__)

    missing =
      for file <- @prompt_building_files, not File.exists?(Path.join(root, file)), do: file

    assert missing == [],
           "prompt-boundary guard lists file(s) that no longer exist: #{inspect(missing)}"
  end
end
