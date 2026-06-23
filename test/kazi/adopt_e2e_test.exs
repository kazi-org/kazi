defmodule Kazi.AdoptE2ETest do
  # T5.6 (UC-023, ADR-0013): the end-to-end + worked-example proof for `kazi init`
  # stack-detection adoption. Unlike Kazi.CLITest's init cases — which synthesise
  # an ephemeral `go.mod` in a tmp dir — this exercises the FULL adopt pipeline
  # (detect -> guards -> writer -> file IO) against the REAL committed fixture repo
  # `fixtures/deploy-target`, and pins the output to the committed worked example
  # `priv/examples/adopt_deploy_target.goal.toml` so the example can never silently
  # drift from what the tool produces.
  #
  # Hermetic: reads the fixture's marker files off disk (no network, no git, no
  # harness — enrichment is off), writes only into the test's tmp_dir, and never
  # mutates the fixture. The same fixture at the same revision always yields the
  # same goal-file (ADR-0013 determinism).
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader

  @fixture_repo "fixtures/deploy-target"
  @worked_example "priv/examples/adopt_deploy_target.goal.toml"

  describe "kazi init against fixtures/deploy-target" do
    @describetag :tmp_dir

    test "writes a goal-file that loads and names `go test ./...`", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "deploy-target.goal.toml")

      {code, output} =
        ExUnit.CaptureIO.with_io(fn ->
          Kazi.CLI.run(["init", @fixture_repo, "--out", out])
        end)

      assert code == 0
      assert output =~ "WROTE  #{out}"

      # The generated goal loads via the same validated Loader the CLI uses...
      assert {:ok, goal} = Loader.load(out)
      assert goal.id == "adopt-deploy-target"

      # ...and its acceptance predicate names the detected Go test command.
      acceptance = Enum.find(goal.predicates, &(&1.id == "tests-pass"))
      assert acceptance, "expected a tests-pass acceptance predicate"
      assert acceptance.kind == :tests
      assert acceptance.config[:cmd] == "go"
      assert acceptance.config[:args] == ["test", "./..."]

      # A conservative baseline regression guard is emitted (Go has no coverage
      # marker, so it is the only guard).
      assert [guard] = goal.guards
      assert guard.id == "tests-pass-baseline"
      assert guard.guard? == true
    end

    test "the live predicate is a COMMENTED TODO, not a loadable predicate",
         %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "deploy-target.goal.toml")

      {0, _output} =
        ExUnit.CaptureIO.with_io(fn ->
          Kazi.CLI.run(["init", @fixture_repo, "--out", out])
        end)

      toml = File.read!(out)

      # The scaffold is present as a comment block (a human fills it in)...
      assert toml =~ "# [[predicate]]"
      assert toml =~ ~s(# provider = "http_probe")
      assert toml =~ "TODO"

      # ...and it does NOT parse into a real predicate: the loaded goal carries
      # only the detected test_runner predicates, no live http_probe/browser one.
      assert {:ok, goal} = Loader.load(out)
      all = goal.predicates ++ goal.guards
      assert Enum.all?(all, &(&1.kind == :tests))
      refute Enum.any?(all, &(&1.kind in [:http_probe, :browser]))
    end

    test "reproduces the committed worked example byte-for-byte", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "deploy-target.goal.toml")

      {0, _output} =
        ExUnit.CaptureIO.with_io(fn ->
          Kazi.CLI.run(["init", @fixture_repo, "--out", out])
        end)

      assert File.read!(out) == File.read!(@worked_example),
             "`kazi init #{@fixture_repo}` drifted from the committed worked example " <>
               "#{@worked_example}; regenerate it with `kazi init #{@fixture_repo} " <>
               "--out #{@worked_example}` and commit the change."
    end

    test "running init does not mutate the fixture repo" do
      before = File.ls!(@fixture_repo) |> Enum.sort()

      System.tmp_dir!()
      out = Path.join(System.tmp_dir!(), "adopt-e2e-#{System.unique_integer([:positive])}.toml")

      {0, _output} =
        ExUnit.CaptureIO.with_io(fn ->
          Kazi.CLI.run(["init", @fixture_repo, "--out", out])
        end)

      assert File.ls!(@fixture_repo) |> Enum.sort() == before,
             "init must not write into the source repo (output goes to --out)"

      File.rm(out)
    end
  end

  describe "the committed worked example" do
    test "loads cleanly via Kazi.Goal.Loader" do
      assert {:ok, goal} = Loader.load(@worked_example)
      assert goal.id == "adopt-deploy-target"

      acceptance = Enum.find(goal.predicates, &(&1.id == "tests-pass"))
      assert acceptance.config[:cmd] == "go"
      assert acceptance.config[:args] == ["test", "./..."]
    end
  end
end
