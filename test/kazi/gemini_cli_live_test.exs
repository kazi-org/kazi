defmodule Kazi.GeminiCliLiveTest do
  @moduledoc """
  Placeholder for the LIVE Gemini CLI smoke test (T37.2, ADR-0022; UC-032).

  The real live body — driving the operator's REAL `gemini` CLI (`gemini -p
  "<prompt>" -o json --approval-mode yolo`) wired to Google via `GEMINI_API_KEY`
  to objective convergence, AND verifying stdout is correct under a non-TTY
  subprocess (the Antigravity bug-#76 failure class) — is T37.2.

  T37.1 only WIRES the profile (`Kazi.Harness.Profiles.GeminiCli`) plus the
  hermetic build_args/golden-transcript tests. This file exists so the
  `:gemini_cli_live` tag is registered (excluded by default in
  `test/test_helper.exs`, alongside `:codex_live`/`:antigravity_live`) and CI
  stays hermetic until T37.2 fills in the live smoke. It makes no convergence
  claim — it is a skipped placeholder, never a fake pass.

  Run (after T37.2 lands the body) with:

      mix test --only gemini_cli_live test/kazi/gemini_cli_live_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :gemini_cli_live

  test "live gemini smoke is implemented in T37.2 (placeholder, excluded by default)" do
    # HONEST non-claim: T37.1 wires the profile + hermetic tests only. The live
    # convergence + non-TTY stdout verification body is T37.2; this placeholder
    # asserts nothing live and never fakes a pass.
    IO.puts(
      "\n[gemini_cli_live] PLACEHOLDER (no convergence claimed): the live smoke body " <>
        "is T37.2; T37.1 wired the :gemini_cli profile + hermetic conformance tests."
    )

    :skipped
  end
end
