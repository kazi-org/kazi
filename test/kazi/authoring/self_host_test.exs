defmodule Kazi.Authoring.SelfHostTest do
  @moduledoc """
  Unit tests for `Kazi.Authoring.SelfHost` (T45.10 exit-proof, #1668/#1669): the
  self-hosting detection the authoring surface uses to (a) flag a `cli`/
  `custom_script` predicate that measures the INSTALLED binary instead of the
  edited source tree, and (b) default a MINIMAL `read_only_paths` lease onto a
  goal whose workspace is kazi's own source.
  """
  use ExUnit.Case, async: true

  alias Kazi.Authoring.SelfHost
  alias Kazi.{Goal, Predicate}

  # --- own_binary_name/1 (I/O: reads <workspace>/mix.exs) ---------------------

  describe "own_binary_name/1" do
    test "resolves the escript name kazi's OWN repo builds" do
      assert SelfHost.own_binary_name(File.cwd!()) == "kazi"
    end

    test "nil when the workspace has no mix.exs" do
      tmp = tmp_workspace()
      assert SelfHost.own_binary_name(tmp) == nil
    after
      :ok
    end

    test "nil when mix.exs declares no escript block" do
      tmp = tmp_workspace()
      File.write!(Path.join(tmp, "mix.exs"), "defmodule Foo.MixProject do\nend\n")
      assert SelfHost.own_binary_name(tmp) == nil
    end

    test "resolves an escript name from an arbitrary workspace's mix.exs" do
      tmp = tmp_workspace()

      File.write!(Path.join(tmp, "mix.exs"), """
      defmodule Foo.MixProject do
        use Mix.Project

        def project do
          [app: :foo, escript: escript()]
        end

        defp escript do
          [main_module: Foo.CLI, name: "foo"]
        end
      end
      """)

      assert SelfHost.own_binary_name(tmp) == "foo"
    end
  end

  # --- at_risk_predicates/2 (pure) --------------------------------------------

  describe "at_risk_predicates/2" do
    test "[] when own_name is nil" do
      goal = goal_with([cli_predicate(:a, "kazi")])
      assert SelfHost.at_risk_predicates(nil, goal) == []
    end

    test "flags a cli predicate whose cmd matches own_name" do
      goal = goal_with([cli_predicate(:a, "kazi")])
      assert SelfHost.at_risk_predicates("kazi", goal) == [:a]
    end

    test "flags a custom_script predicate whose cmd matches own_name" do
      goal = goal_with([Predicate.new(:a, :custom_script, config: %{cmd: "kazi"})])
      assert SelfHost.at_risk_predicates("kazi", goal) == [:a]
    end

    test "does not flag a predicate whose cmd does not match" do
      goal = goal_with([cli_predicate(:a, "terraform")])
      assert SelfHost.at_risk_predicates("kazi", goal) == []
    end

    test "does not flag a non-cli/custom_script predicate" do
      goal = goal_with([Predicate.new(:a, :http_probe, config: %{url: "https://x.test"})])
      assert SelfHost.at_risk_predicates("kazi", goal) == []
    end
  end

  # --- default_read_only_paths/2 (I/O: checks <workspace>/lib/kazi/providers) -

  describe "default_read_only_paths/2" do
    test "[] against an ordinary (non-kazi-source) workspace" do
      tmp = tmp_workspace()
      goal = goal_with([cli_predicate(:a, "kazi")])
      assert SelfHost.default_read_only_paths(tmp, goal) == []
    end

    test "derives the minimal provider files for THIS goal's own predicate kinds against kazi's own tree" do
      goal =
        goal_with([
          cli_predicate(:cli_check, "kazi"),
          Predicate.new(:probe, :http_probe, config: %{url: "https://x.test"})
        ])

      paths = SelfHost.default_read_only_paths(File.cwd!(), goal)

      assert "lib/kazi/providers/cli.ex" in paths
      assert "lib/kazi/providers/command_runner.ex" in paths
      assert "lib/kazi/providers/http_probe.ex" in paths
      # unrelated providers this goal does not use stay fully editable
      refute "lib/kazi/providers/browser.ex" in paths
      refute "lib/kazi/providers/mutation.ex" in paths
    end

    test "[] when the goal names no kind kazi ships a provider file for" do
      goal = Goal.new("g", mode: :create, predicates: [])
      assert SelfHost.default_read_only_paths(File.cwd!(), goal) == []
    end
  end

  # --- default_enforcement/2 (overlays the lease onto Enforcement.resolve/1) --
  #
  # The team-lead review caught a real defect in the first cut: constructing a
  # fresh `Kazi.Enforcement.new(enabled: true, ...)` from scratch hardcodes
  # `enabled: true` (plus the struct's `clean_tree: true`/`fail_on_skip: true`
  # defaults) regardless of what the goal's OWN mode would otherwise resolve to.
  # `default_enforcement/2` instead resolves the profile the goal would have
  # gotten anyway (`Kazi.Enforcement.resolve/1`, mode-respecting) and overlays
  # ONLY `read_only_paths` -- so a goal whose enforcement would be OFF (a
  # `:repair` goal, ADR-0042's opt-in policy) stays off; the lease is merely
  # pre-populated for whenever enforcement IS active.
  describe "default_enforcement/2" do
    test "nil against an ordinary (non-kazi-source) workspace" do
      tmp = tmp_workspace()
      goal = goal_with([cli_predicate(:a, "kazi")])
      assert SelfHost.default_enforcement(tmp, goal) == nil
    end

    test "nil when the goal names no kind kazi ships a provider file for" do
      goal = Goal.new("g", mode: :create, predicates: [])
      assert SelfHost.default_enforcement(File.cwd!(), goal) == nil
    end

    test "a :create-mode goal (ADR-0042 default-on) gets an ACTIVE profile with the lease" do
      goal = goal_with([cli_predicate(:a, "kazi")], mode: :create)

      assert %Kazi.Enforcement{enabled: true, clean_tree: true, fail_on_skip: true} =
               enforcement = SelfHost.default_enforcement(File.cwd!(), goal)

      assert "lib/kazi/providers/cli.ex" in enforcement.read_only_paths
    end

    # The case the team-lead review flagged: a self-hosted :repair goal must
    # NOT be switched from "enforcement off" to "enforcement on" merely because
    # it happens to run against kazi's own tree. `Kazi.Enforcement.resolve/1`'s
    # own opt-in-for-repair policy must still be what decides `enabled`.
    test ":repair-mode goal (ADR-0042 opt-in) stays enabled: false -- the lease is present but inert" do
      goal = goal_with([cli_predicate(:a, "kazi")], mode: :repair)

      assert %Kazi.Enforcement{enabled: false} =
               enforcement = SelfHost.default_enforcement(File.cwd!(), goal)

      # The lease is still populated (so it is already there the moment a human
      # later flips `enabled: true`), but inert: every enforcement check gates
      # on `enabled: true` first (Kazi.Enforcement.enforce_result/2, isolate?/1,
      # guarantee_atoms/1), so a false `enabled` here can never itself trigger
      # clean-tree isolation or a read-only-write flag.
      assert "lib/kazi/providers/cli.ex" in enforcement.read_only_paths
      refute Kazi.Enforcement.active?(enforcement)
      assert Kazi.Enforcement.guarantee_atoms(enforcement) == []

      assert Kazi.Enforcement.enforce_result(enforcement, Kazi.PredicateResult.pass(%{})) ==
               Kazi.PredicateResult.pass(%{})
    end

    test "a goal that already authors its own [enforcement] block is untouched by resolve/1's default" do
      # (default_enforcement/2 is only ever called by Kazi.Authoring when the
      # goal's enforcement is nil -- pinning that Enforcement.resolve/1 itself
      # honors an already-authored profile verbatim, so the caller-side nil
      # guard is sufficient and not accidentally bypassable here.)
      authored = Kazi.Enforcement.new(enabled: false, clean_tree: false)
      goal = %{goal_with([cli_predicate(:a, "kazi")], mode: :create) | enforcement: authored}

      assert Kazi.Enforcement.resolve(goal) == authored
    end
  end

  defp cli_predicate(id, cmd) do
    Predicate.new(id, :cli, config: %{cmd: cmd, assertions: [%{"target" => "exit_code"}]})
  end

  defp goal_with(predicates, opts \\ []) do
    Goal.new("g", mode: Keyword.get(opts, :mode, :create), predicates: predicates)
  end

  defp tmp_workspace do
    path =
      Path.join(System.tmp_dir!(), "kazi_self_host_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit_cleanup(path)
    path
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
  end
end
