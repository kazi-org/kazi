defmodule Kazi.AdoptTest do
  # T5.1: deterministic stack + test-command detection (ADR-0013, UC-023).
  # Hermetic — reads committed fixture repos under test/fixtures/adopt and an
  # injected in-memory reader; no network, no shelling out, no git clone.
  use ExUnit.Case, async: true

  alias Kazi.Adopt
  alias Kazi.AdoptTest.InMemoryReader
  alias Kazi.Goal
  alias Kazi.Goal.Loader

  @fixtures Path.expand("../fixtures/adopt", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  describe "detect/1 stack mapping" do
    test "go.mod -> go test ./..." do
      assert {:ok, %{stack: :go, predicate: predicate}} = Adopt.detect(fixture("go"))
      assert predicate["provider"] == "test_runner"
      assert predicate["cmd"] == "go"
      assert predicate["args"] == ["test", "./..."]
    end

    test "mix.exs -> mix test" do
      assert {:ok, %{stack: :elixir, predicate: predicate}} = Adopt.detect(fixture("elixir"))
      assert predicate["cmd"] == "mix"
      assert predicate["args"] == ["test"]
    end

    test "package.json with a real test script -> npm test" do
      assert {:ok, %{stack: :node, predicate: predicate}} =
               Adopt.detect(fixture("node-with-test"))

      assert predicate["cmd"] == "npm"
      assert predicate["args"] == ["test"]
    end

    test "pyproject.toml -> pytest" do
      assert {:ok, %{stack: :python, predicate: predicate}} =
               Adopt.detect(fixture("python-pyproject"))

      assert predicate["cmd"] == "pytest"
      assert predicate["args"] == []
    end

    test "setup.cfg -> pytest" do
      assert {:ok, %{stack: :python, predicate: predicate}} =
               Adopt.detect(fixture("python-setupcfg"))

      assert predicate["cmd"] == "pytest"
      assert predicate["args"] == []
    end
  end

  describe "detect/1 no-detection" do
    test "an unknown stack yields a clear tagged result, not a crash" do
      assert {:error, :no_stack_detected} = Adopt.detect(fixture("unknown"))
    end

    test "package.json with no test script is no-detection" do
      assert {:error, :no_stack_detected} = Adopt.detect(fixture("node-no-test"))
    end

    test "package.json with the npm-init placeholder test is no-detection" do
      assert {:error, :no_stack_detected} = Adopt.detect(fixture("node-placeholder"))
    end

    test "a nonexistent path is no-detection, not a crash" do
      assert {:error, :no_stack_detected} = Adopt.detect(fixture("does-not-exist"))
    end
  end

  describe "detect/1 determinism" do
    test "the same repo yields byte-identical results across runs" do
      assert Adopt.detect(fixture("go")) == Adopt.detect(fixture("go"))
      assert Adopt.detect(fixture("node-with-test")) == Adopt.detect(fixture("node-with-test"))
    end

    test "a polyglot repo resolves deterministically to the first-ordered stack (Go)" do
      assert {:ok, %{stack: :go}} = Adopt.detect(fixture("polyglot"))
    end
  end

  describe "detect/1 predicate round-trips through Kazi.Goal.Loader" do
    test "the detected predicate map loads into a runnable :tests predicate" do
      assert {:ok, %{predicate: predicate}} = Adopt.detect(fixture("go"))

      goal_map = %{
        "id" => "adopt-go",
        "predicate" => [predicate]
      }

      assert {:ok, %Goal{} = goal} = Loader.from_map(goal_map)
      assert [loaded] = goal.predicates
      assert loaded.kind == :tests
      assert loaded.config[:cmd] == "go"
      assert loaded.config[:args] == ["test", "./..."]
    end
  end

  describe "detect/1 hermetic file-reader seam" do
    test "reads marker files through an injected in-memory reader" do
      reader = InMemoryReader.new(%{"go.mod" => "module example.com/app\n"})

      assert {:ok, %{stack: :go, predicate: predicate}} =
               Adopt.detect("/virtual/repo", file_reader: reader)

      assert predicate["cmd"] == "go"
    end

    test "an injected reader with no markers is no-detection" do
      reader = InMemoryReader.new(%{"README.md" => "hi"})
      assert {:error, :no_stack_detected} = Adopt.detect("/virtual/repo", file_reader: reader)
    end

    test "derives the node command from an injected package.json" do
      reader =
        InMemoryReader.new(%{
          "package.json" => ~s({"scripts":{"test":"jest"}})
        })

      assert {:ok, %{stack: :node, predicate: predicate}} =
               Adopt.detect("/virtual/repo", file_reader: reader)

      assert predicate["cmd"] == "npm"
    end
  end

  describe "guards/1 baseline" do
    test "a detected stack always yields a tests-pass baseline guard" do
      assert {:ok, detection} = Adopt.detect(fixture("go"))
      assert [baseline] = Adopt.guards(detection, path: fixture("go"))

      assert baseline["id"] == "tests-pass-baseline"
      assert baseline["provider"] == "test_runner"
      assert baseline["guard"] == true
      # The baseline reuses the detected test command as an invariant.
      assert baseline["cmd"] == "go"
      assert baseline["args"] == ["test", "./..."]
    end

    test "a stack with no coverage tool yields ONLY the baseline" do
      # Plain elixir fixture (mix.exs without excoveralls) -> baseline only.
      assert {:ok, detection} = Adopt.detect(fixture("elixir"))
      assert [baseline] = Adopt.guards(detection, path: fixture("elixir"))
      assert baseline["id"] == "tests-pass-baseline"

      # Node-with-test (vitest run, no coverage flag) -> baseline only.
      assert {:ok, node} = Adopt.detect(fixture("node-with-test"))
      assert [node_baseline] = Adopt.guards(node, path: fixture("node-with-test"))
      assert node_baseline["id"] == "tests-pass-baseline"

      # Go has no coverage config marker -> baseline only (conservative).
      assert {:ok, go} = Adopt.detect(fixture("go"))
      assert [go_baseline] = Adopt.guards(go, path: fixture("go"))
      assert go_baseline["id"] == "tests-pass-baseline"
    end
  end

  describe "guards/1 coverage ratchet" do
    test "elixir with excoveralls yields a coverage-ratchet guard" do
      assert {:ok, detection} = Adopt.detect(fixture("elixir-coverage"))
      assert [baseline, coverage] = Adopt.guards(detection, path: fixture("elixir-coverage"))

      assert baseline["id"] == "tests-pass-baseline"
      assert coverage["id"] == "coverage-ratchet"
      assert coverage["provider"] == "test_runner"
      assert coverage["guard"] == true
      assert coverage["cmd"] == "mix"
      assert coverage["args"] == ["coveralls"]
    end

    test "node with nyc yields a coverage-ratchet guard that enforces a threshold" do
      assert {:ok, detection} = Adopt.detect(fixture("node-coverage"))
      assert [_baseline, coverage] = Adopt.guards(detection, path: fixture("node-coverage"))

      assert coverage["id"] == "coverage-ratchet"
      assert coverage["cmd"] == "npx"
      assert coverage["args"] == ["nyc", "--check-coverage", "npm", "test"]
    end

    test "python with pytest-cov yields a coverage-ratchet guard" do
      assert {:ok, detection} = Adopt.detect(fixture("python-coverage"))
      assert [_baseline, coverage] = Adopt.guards(detection, path: fixture("python-coverage"))

      assert coverage["id"] == "coverage-ratchet"
      assert coverage["cmd"] == "pytest"
      assert coverage["args"] == ["--cov", "--cov-fail-under=0"]
    end

    test "coverage detection works through the injected in-memory reader" do
      reader =
        InMemoryReader.new(%{
          "mix.exs" => "deps: [{:excoveralls, \"~> 0.18\", only: :test}]"
        })

      detection = %{
        stack: :elixir,
        predicate: %{"cmd" => "mix", "args" => ["test"]}
      }

      assert [_baseline, coverage] = Adopt.guards(detection, file_reader: reader)
      assert coverage["id"] == "coverage-ratchet"
    end
  end

  describe "guards/1 invariants" do
    test "every emitted guard is evaluable by an existing provider (test_runner)" do
      for name <- ["go", "elixir", "node-with-test", "elixir-coverage", "node-coverage"] do
        assert {:ok, detection} = Adopt.detect(fixture(name))
        guards = Adopt.guards(detection, path: fixture(name))

        # NEVER emit a guard kazi cannot evaluate: the only command-running
        # provider is test_runner, so every guard must use it.
        for guard <- guards do
          assert guard["provider"] == "test_runner"
          assert guard["guard"] == true
        end
      end
    end

    test "every emitted guard round-trips through Kazi.Goal.Loader as an invariant" do
      assert {:ok, detection} = Adopt.detect(fixture("elixir-coverage"))
      guards = Adopt.guards(detection, path: fixture("elixir-coverage"))

      goal_map = %{
        "id" => "adopt-guards",
        # A goal needs a non-guard predicate too; use the detected one.
        "predicate" => [detection.predicate | guards]
      }

      assert {:ok, %Goal{} = goal} = Loader.from_map(goal_map)
      # The two guard maps land in goal.guards as invariants.
      assert length(goal.guards) == 2
      assert Enum.all?(goal.guards, & &1.guard?)
      assert Enum.all?(goal.guards, &(&1.kind == :tests))
    end

    test "guards/1 is deterministic across runs" do
      assert {:ok, detection} = Adopt.detect(fixture("elixir-coverage"))

      assert Adopt.guards(detection, path: fixture("elixir-coverage")) ==
               Adopt.guards(detection, path: fixture("elixir-coverage"))
    end
  end

  # An in-memory file reader honoring the `File` contract (`regular?/1`,
  # `read/1`) used by `Kazi.Adopt`'s injectable seam. Keys are repo-relative
  # marker names; `Path.join(root, marker)` is matched on its trailing segment so
  # the virtual root is irrelevant.
  defmodule InMemoryReader do
    @moduledoc false

    # Returns the `{module, state}` seam tuple Kazi.Adopt threads through
    # regular?/2 and read/2. `state` is the file map; keys are marker names
    # matched on the trailing path segment, so the virtual root is irrelevant.
    def new(files) when is_map(files), do: {__MODULE__, files}

    def regular?(files, path), do: Map.has_key?(files, marker(path))

    def read(files, path) do
      case Map.fetch(files, marker(path)) do
        {:ok, contents} -> {:ok, contents}
        :error -> {:error, :enoent}
      end
    end

    defp marker(path), do: Path.basename(path)
  end
end
