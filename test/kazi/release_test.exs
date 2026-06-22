defmodule Kazi.ReleaseTest do
  @moduledoc """
  Wiring guard for the Burrito binary entry (T6.2, ADR-0014).

  `Kazi.Release.cli/1` and `Kazi.Release.burrito_main/0` both end in
  `System.halt/1`, so they cannot be driven to completion inside the test VM
  (halting kills the ExUnit run). Their shared, halt-free core — argv parsing,
  the run, the outcome report — is already exercised end-to-end by
  `Kazi.CLITest` and `Kazi.CLIAuthoringTest` through `Kazi.CLI.run/1`.

  This module instead pins the contract that makes the Burrito entry *reachable
  and correct* without invoking the halting functions:

    * the Burrito runtime API the binary depends on exists (so a build that
      drops the dep, or a Burrito upgrade that renames the API, fails here rather
      than only at `kazi run` time inside a shipped binary);
    * the standalone-Burrito detection is correctly OFF in every non-binary
      entry (test, dev, `mix kazi.run`, the release `eval` path), which is *why*
      `Kazi.Application.start/2` boots the normal supervision tree here instead
      of dispatching the CLI and halting — the 714-test suite booting the app at
      all is the live proof of that branch;
    * `burrito_main/0` is exported with the entry arity `Kazi.Application`
      dispatches to.
  """
  use ExUnit.Case, async: true

  describe "Burrito runtime API the wrapped binary depends on" do
    test "Burrito.Util.Args.argv/0 is available (the binary reads its argv through it)" do
      # The wrapped binary boots the release rather than taking an `eval`
      # argument, so the operator's argv arrives via Burrito, not System.argv/0.
      # `burrito_main/0` calls exactly this; assert it is loadable & exported.
      assert Code.ensure_loaded?(Burrito.Util.Args)
      assert function_exported?(Burrito.Util.Args, :argv, 0)
    end

    test "Burrito.Util.running_standalone?/0 is available (the start/2 gate uses it)" do
      assert Code.ensure_loaded?(Burrito.Util)
      assert function_exported?(Burrito.Util, :running_standalone?, 0)
    end
  end

  describe "standalone-Burrito detection" do
    test "is OFF outside a Burrito binary (no __BURRITO env), so the app starts normally" do
      # Burrito sets the `__BURRITO` env var only when its launcher boots the
      # wrapped binary. In the test VM (and dev, `mix kazi.run`, the release
      # `eval` path) it is unset, so detection is false and Kazi.Application
      # stands up the supervision tree instead of dispatching + halting.
      refute Burrito.Util.running_standalone?()
      assert System.get_env("__BURRITO") == nil
    end
  end

  describe "entrypoints" do
    test "burrito_main/0 is exported as the Burrito binary entry" do
      # Kazi.Application.start/2 dispatches to this exact function/arity when it
      # detects a standalone Burrito run.
      assert Code.ensure_loaded?(Kazi.Release)
      assert function_exported?(Kazi.Release, :burrito_main, 0)
    end

    test "cli/1 (the eval entry) remains exported for a plain mix release" do
      assert Code.ensure_loaded?(Kazi.Release)
      assert function_exported?(Kazi.Release, :cli, 1)
    end
  end
end
