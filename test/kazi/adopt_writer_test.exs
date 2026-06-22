defmodule Kazi.AdoptWriterTest do
  # T5.3: the goal-file writer (ADR-0013, ADR-0015). Renders an adopted goal map
  # to a TOML goal-file string. Pure and hermetic — no disk, no network. The two
  # load-bearing invariants are asserted directly: determinism (byte-identical
  # output) and round-trip (the uncommented part decodes + loads cleanly).
  use ExUnit.Case, async: true

  alias Kazi.Adopt
  alias Kazi.Adopt.Writer
  alias Kazi.Goal
  alias Kazi.Goal.Loader

  # Count REAL (non-commented) `[[predicate]]` blocks: lines whose first
  # non-space char is `[`, not `#`.
  defp real_predicate_blocks(toml) do
    toml
    |> String.split("\n")
    |> Enum.count(&(String.trim(&1) == "[[predicate]]"))
  end

  # A representative adopted goal map: a detected test_runner acceptance
  # predicate plus a baseline guard — exactly what detect/1 + guards/1 produce.
  defp goal_map do
    %{
      "id" => "adopt-go",
      "name" => "Adopted: example.com/app",
      "predicate" => [
        %{
          "id" => "tests-pass",
          "provider" => "test_runner",
          "description" => "project test suite passes",
          "cmd" => "go",
          "args" => ["test", "./..."]
        },
        %{
          "id" => "tests-pass-baseline",
          "provider" => "test_runner",
          "description" => "project test suite keeps passing (baseline regression guard)",
          "guard" => true,
          "cmd" => "go",
          "args" => ["test", "./..."]
        }
      ]
    }
  end

  describe "to_toml/1 structure" do
    test "emits the top-level id/name and one [[predicate]] block per predicate" do
      toml = Writer.to_toml(goal_map())

      assert toml =~ ~s(id = "adopt-go")
      assert toml =~ ~s(name = "Adopted: example.com/app")
      # Two REAL (non-commented) predicate blocks.
      assert real_predicate_blocks(toml) == 2

      # The test_runner predicate names the declared command.
      assert toml =~ ~s(provider = "test_runner")
      assert toml =~ ~s(cmd = "go")
      assert toml =~ ~s(args = ["test", "./..."])
      # The guard predicate carries guard = true.
      assert toml =~ "guard = true"
    end

    test "appends a COMMENTED live-predicate scaffold with TODO placeholders" do
      toml = Writer.to_toml(goal_map())

      assert toml =~ "# [[predicate]]"
      assert toml =~ ~s(# provider = "http_probe")
      assert toml =~ "TODO"
      # The scaffold is a comment: it does not introduce a third real predicate.
      assert real_predicate_blocks(toml) == 2
    end

    test "Kazi.Adopt.to_toml/1 delegates to the writer (same output)" do
      assert Adopt.to_toml(goal_map()) == Writer.to_toml(goal_map())
    end

    test "renders an optional [scope] table when present" do
      map = Map.put(goal_map(), "scope", %{"workspace" => "/srv/app", "paths" => ["lib"]})
      toml = Writer.to_toml(map)

      assert toml =~ "[scope]"
      assert toml =~ ~s(workspace = "/srv/app")
      assert toml =~ ~s(paths = ["lib"])
    end
  end

  describe "to_toml/1 determinism" do
    test "the same map renders byte-identically across runs" do
      assert Writer.to_toml(goal_map()) == Writer.to_toml(goal_map())
    end

    test "key order within a predicate is stable regardless of input map order" do
      a = %{
        "id" => "p",
        "provider" => "test_runner",
        "cmd" => "go",
        "args" => ["test"],
        "zeta" => "z",
        "alpha" => "a"
      }

      # Same predicate, keys inserted in a different order.
      b = %{
        "alpha" => "a",
        "args" => ["test"],
        "zeta" => "z",
        "cmd" => "go",
        "provider" => "test_runner",
        "id" => "p"
      }

      map_a = %{"id" => "g", "predicate" => [a]}
      map_b = %{"id" => "g", "predicate" => [b]}

      assert Writer.to_toml(map_a) == Writer.to_toml(map_b)
    end
  end

  describe "to_toml/1 round-trips through Kazi.Goal.Loader" do
    test "the emitted goal-file decodes via Toml and loads via the Loader" do
      toml = Writer.to_toml(goal_map())

      assert {:ok, decoded} = Toml.decode(toml)
      assert {:ok, %Goal{} = goal} = Loader.from_map(decoded)

      assert goal.id == "adopt-go"
      assert goal.name == "Adopted: example.com/app"
      # One acceptance predicate + one guard.
      assert [acceptance] = goal.predicates
      assert acceptance.id == "tests-pass"
      assert acceptance.kind == :tests
      assert acceptance.config[:cmd] == "go"

      assert [guard] = goal.guards
      assert guard.id == "tests-pass-baseline"
      assert guard.guard? == true
    end

    test "strings with TOML-special characters are escaped and round-trip" do
      map = %{
        "id" => "esc",
        "predicate" => [
          %{
            "id" => "p",
            "provider" => "test_runner",
            "description" => ~s(a "quoted" path C:\\tmp and a\ttab),
            "cmd" => "sh",
            "args" => ["-c", ~s(echo "hi")]
          }
        ]
      }

      toml = Writer.to_toml(map)
      assert {:ok, decoded} = Toml.decode(toml)
      assert {:ok, %Goal{} = goal} = Loader.from_map(decoded)
      assert [p] = goal.predicates
      assert p.description == ~s(a "quoted" path C:\\tmp and a\ttab)
      assert p.config[:args] == ["-c", ~s(echo "hi")]
    end
  end

  describe "live_predicate_scaffold/0" do
    test "is a comment block that does NOT parse as a predicate" do
      scaffold = Writer.live_predicate_scaffold()
      # Every non-blank line is a comment.
      assert scaffold
             |> String.split("\n")
             |> Enum.reject(&(&1 == ""))
             |> Enum.all?(&String.starts_with?(&1, "#"))
    end
  end
end
