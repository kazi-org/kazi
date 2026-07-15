defmodule Kazi.CLISpecImportTest do
  @moduledoc """
  T40.2 (ADR-0050): `kazi spec import <feature-file>... --into <goal-file>` is
  CLI wiring over the already-tested `Kazi.Reconcile.GherkinImporter`
  (ADR-0021/T13.2). It derives one `test_runner` acceptance predicate per
  Gherkin Scenario (grouped by Feature) and UPSERTS them into the goal-file.

  HERMETIC: pure filesystem + the deterministic importer — no read-model, no
  network, no harness. Each test writes its `.feature` fixture and target under a
  fresh tmp dir.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.Goal

  @feature """
  Feature: Sign Up
    Scenario: A new user signs up
      Given a visitor on the home page
      When they submit the sign-up form
      Then their account is created

    Scenario: A duplicate email is rejected
      Given an existing account
      When a visitor signs up with the same email
      Then the form shows a duplicate error
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-spec-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    feature = Path.join(dir, "sign_up.feature")
    File.write!(feature, @feature)

    {:ok, dir: dir, feature: feature}
  end

  describe "spec import — derive predicates into a fresh goal-file" do
    test "creates the goal-file with one test_runner predicate per Scenario, grouped by Feature",
         %{dir: dir, feature: feature} do
      into = Path.join(dir, "sign-up.goal.toml")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["spec", "import", feature, "--into", into, "--json"]) == 0
        end)

      assert {:ok, result} = Jason.decode(String.trim(out))
      assert result["ok"] == true
      assert result["into"] == into
      assert result["merged"] == false
      assert result["count"] == 2

      assert Enum.sort(result["upserted"]) == [
               "sign-up__a-duplicate-email-is-rejected",
               "sign-up__a-new-user-signs-up"
             ]

      # The written file loads through the validated loader.
      assert {:ok, %Goal{} = goal} = Goal.Loader.load(into)
      predicates = Goal.all_predicates(goal)
      assert length(predicates) == 2
      # Migrated to custom_script scaffolds (ADR-0040/E40): each is RED until a
      # human wires the real check.
      assert Enum.all?(predicates, &(&1.kind == :custom_script))
      assert Enum.all?(predicates, &(&1.group == "sign-up"))
    end

    test "the human surface reports the count, the ids, and the runnable hint", %{
      dir: dir,
      feature: feature
    } do
      into = Path.join(dir, "human.goal.toml")

      stdout =
        capture_io(fn ->
          assert Kazi.CLI.run(["spec", "import", feature, "--into", into]) == 0
        end)

      assert stdout =~ "IMPORTED"
      assert stdout =~ "sign-up__a-new-user-signs-up"
      assert stdout =~ "kazi apply #{into}"
    end
  end

  describe "spec import — re-import is an upsert" do
    test "re-importing the same spec keeps ids and adds no duplicate", %{
      dir: dir,
      feature: feature
    } do
      into = Path.join(dir, "upsert.goal.toml")

      capture_io(fn ->
        assert Kazi.CLI.run(["spec", "import", feature, "--into", into]) == 0
      end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["spec", "import", feature, "--into", into, "--json"]) == 0
        end)

      assert {:ok, result} = Jason.decode(String.trim(out))
      assert result["merged"] == true

      # Still exactly two predicates — an upsert, not a duplicate.
      assert {:ok, %Goal{} = goal} = Goal.Loader.load(into)
      assert length(Goal.all_predicates(goal)) == 2
    end

    test "a hand-added live predicate in the target survives a re-import", %{
      dir: dir,
      feature: feature
    } do
      into = Path.join(dir, "with-live.goal.toml")

      capture_io(fn ->
        assert Kazi.CLI.run(["spec", "import", feature, "--into", into]) == 0
      end)

      # Append a hand-authored live predicate to the generated goal-file.
      File.write!(
        into,
        File.read!(into) <>
          """

          [[predicate]]
          id = "live-probe"
          provider = "http_probe"
          description = "the deployed service is healthy"
          url = "https://example.test/healthz"
          expect_status = 200
          """
      )

      capture_io(fn ->
        assert Kazi.CLI.run(["spec", "import", feature, "--into", into]) == 0
      end)

      assert {:ok, %Goal{} = goal} = Goal.Loader.load(into)
      ids = goal |> Goal.all_predicates() |> Enum.map(&to_string(&1.id))
      assert "live-probe" in ids
      assert length(ids) == 3
    end
  end

  describe "spec import — usage errors" do
    test "missing --into is a clear error, exit 1", %{feature: feature} do
      stderr =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["spec", "import", feature]) == 2
        end)

      assert stderr =~ "--into"
    end

    test "an unreadable feature file errors on the requested surface", %{dir: dir} do
      into = Path.join(dir, "x.goal.toml")
      missing = Path.join(dir, "nope.feature")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["spec", "import", missing, "--into", into, "--json"]) == 1
        end)

      assert {:ok, %{"error" => message}} = Jason.decode(String.trim(out))
      assert message =~ "could not read feature file"
      refute File.exists?(into)
    end

    test "an unknown spec subcommand is a usage error" do
      stderr =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["spec", "explode"]) == 2
        end)

      assert stderr =~ "unknown spec subcommand"
    end
  end
end
