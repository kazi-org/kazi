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

  describe "to_toml/1 — optional [harness] table (T8.6, ADR-0016)" do
    test "emits nothing for a map with no harness (existing output unchanged)" do
      with_harness = Writer.to_toml(Map.put(goal_map(), "harness", nil))
      without = Writer.to_toml(goal_map())

      refute with_harness =~ "[harness]"
      assert with_harness == without
    end

    test "emits a [harness] table with only the recognized keys, in stable order" do
      map =
        Map.put(goal_map(), "harness", %{
          "id" => "opencode",
          "model" => "local/qwen3.6",
          "command" => "/usr/local/bin/opencode",
          # an unrecognized key must NOT be emitted (so output round-trips).
          "ignored" => "drop-me"
        })

      toml = Writer.to_toml(map)

      assert toml =~ "[harness]"
      assert toml =~ ~s(id = "opencode")
      assert toml =~ ~s(model = "local/qwen3.6")
      assert toml =~ ~s(command = "/usr/local/bin/opencode")
      refute toml =~ "ignored"
      refute toml =~ "drop-me"

      # id before model before command (deterministic order).
      id_at = :binary.match(toml, "id = \"opencode\"") |> elem(0)
      model_at = :binary.match(toml, "model =") |> elem(0)
      command_at = :binary.match(toml, "command =") |> elem(0)
      assert id_at < model_at and model_at < command_at
    end

    test "an empty harness map emits nothing" do
      assert Writer.to_toml(Map.put(goal_map(), "harness", %{})) == Writer.to_toml(goal_map())
    end

    test "is deterministic — same harness map renders byte-identically" do
      map = Map.put(goal_map(), "harness", %{"id" => "opencode", "model" => "local/qwen3.6"})
      assert Writer.to_toml(map) == Writer.to_toml(map)
    end

    test "round-trips: a harness table renders and re-loads to the same values" do
      map = Map.put(goal_map(), "harness", %{"id" => "opencode", "model" => "local/qwen3.6"})

      toml = Writer.to_toml(map)
      assert {:ok, decoded} = Toml.decode(toml)
      assert {:ok, %Goal{harness: harness}} = Loader.from_map(decoded)

      assert harness == %{
               id: :opencode,
               model: "local/qwen3.6",
               command: nil,
               effort: nil,
               permission_mode: nil,
               allowed_tools: nil
             }
    end
  end

  describe "to_toml/2 — T48.9 learned [budget] suggestion (ADR-0058 decision 2)" do
    @suggestion %{
      max_tokens: 750_000,
      max_dispatches: 6,
      max_wall_clock_ms: 600_000,
      provenance: "learned from 12 runs (shape 4-8, any model/harness), p95 x 1.5"
    }

    test "to_toml/1 (no suggestion) is byte-identical to to_toml/2 called with nil" do
      assert Writer.to_toml(goal_map()) == Writer.to_toml(goal_map(), nil)
    end

    test "a nil suggestion adds nothing (no [budget] mention at all)" do
      refute Writer.to_toml(goal_map(), nil) =~ "budget"
    end

    test "renders a COMMENTED [budget] block with the provenance line" do
      toml = Writer.to_toml(goal_map(), @suggestion)

      assert toml =~ "# suggested by kazi economy: #{@suggestion.provenance}"
      assert toml =~ "# [budget]"
      assert toml =~ "# max_tokens = 750000"
      assert toml =~ "# max_dispatches = 6"
      assert toml =~ "# max_wall_clock_ms = 600000"
      # It is a COMMENT: it never introduces a real [[predicate]] or a live
      # [budget] table.
      refute toml =~ ~r/^\[budget\]/m
    end

    test "the suggestion NEVER parses into a real budget (never silently applied)" do
      toml = Writer.to_toml(goal_map(), @suggestion)

      assert {:ok, decoded} = Toml.decode(toml)
      assert {:ok, %Goal{budget: budget}} = Loader.from_map(decoded)

      # A commented [budget] table does not parse -- the loaded goal carries
      # the loader's all-nil default, never the suggested ceilings.
      assert budget.max_tokens == nil
      assert budget.max_dispatches == nil
      assert budget.max_wall_clock_ms == nil
    end

    test "a metric absent from the suggestion (honest-unknown) renders no line for it" do
      partial = %{
        max_dispatches: 3,
        provenance: "learned from 2 runs (shape 1-3, any model/harness), p95 x 1.5"
      }

      toml = Writer.to_toml(goal_map(), partial)

      assert toml =~ "# max_dispatches = 3"
      refute toml =~ "max_tokens"
      refute toml =~ "max_wall_clock_ms"
    end

    test "is deterministic — the same suggestion renders byte-identically" do
      assert Writer.to_toml(goal_map(), @suggestion) == Writer.to_toml(goal_map(), @suggestion)
    end

    test "Kazi.Adopt.to_toml/2 delegates to the writer (same output)" do
      assert Adopt.to_toml(goal_map(), @suggestion) == Writer.to_toml(goal_map(), @suggestion)
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

  # T39.3 (ADR-0049): to_goal_file/1 materializes an ALREADY-AUTHORED goal — the
  # full serialize_goal/1 map (mode/standing/metadata/group), NO live-scaffold.
  describe "to_goal_file/1 (the approve --write materializer)" do
    defp authored_map(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => "authored-goal",
          "name" => "An authored goal",
          "mode" => "repair",
          "standing" => false,
          "group" => [],
          "metadata" => %{"source" => "authoring", "proposed" => true},
          "predicate" => [
            %{
              "id" => "code",
              "provider" => "test_runner",
              "description" => "tests pass",
              "cmd" => "sh",
              "args" => ["-c", "true"]
            }
          ]
        },
        overrides
      )
    end

    test "emits NO live-predicate scaffold (an approved goal is complete)" do
      toml = Writer.to_goal_file(authored_map())

      refute toml =~ "TODO"
      refute toml =~ "live-probe"
      # No commented predicate block at all.
      refute toml =~ "# [[predicate]]"
    end

    test "round-trips: the emitted TOML loads to the same id and predicate set" do
      toml = Writer.to_goal_file(authored_map())

      assert {:ok, decoded} = Toml.decode(toml)
      assert {:ok, %Goal{} = goal} = Loader.from_map(decoded)
      assert goal.id == "authored-goal"
      assert goal |> Goal.all_predicates() |> Enum.map(&to_string(&1.id)) == ["code"]
    end

    test "omits default mode/standing but carries create-mode and standing when set" do
      repair = Writer.to_goal_file(authored_map())
      refute repair =~ "mode ="
      refute repair =~ "standing ="

      special = Writer.to_goal_file(authored_map(%{"mode" => "create", "standing" => true}))
      assert special =~ ~s(mode = "create")
      assert special =~ "standing = true"
    end

    test "renders a [metadata] table that round-trips" do
      toml = Writer.to_goal_file(authored_map())

      assert toml =~ "[metadata]"
      assert {:ok, decoded} = Toml.decode(toml)
      assert decoded["metadata"]["source"] == "authoring"
      assert decoded["metadata"]["proposed"] == true
    end

    test "renders [[group]] blocks that round-trip through the loader" do
      groups = [%{"id" => "core", "name" => "Core"}, %{"id" => "extra", "name" => "Extra"}]

      predicate = %{
        "id" => "code",
        "provider" => "test_runner",
        "description" => "tests pass",
        "group" => "core",
        "cmd" => "sh",
        "args" => ["-c", "true"]
      }

      toml =
        Writer.to_goal_file(authored_map(%{"group" => groups, "predicate" => [predicate]}))

      assert toml =~ "[[group]]"
      assert {:ok, %Goal{} = goal} = toml |> Toml.decode!() |> Loader.from_map()
      assert goal.groups |> Enum.map(& &1.id) |> Enum.sort() == ["core", "extra"]
    end

    test "is deterministic — same map renders byte-identically" do
      assert Writer.to_goal_file(authored_map()) == Writer.to_goal_file(authored_map())
    end
  end
end
