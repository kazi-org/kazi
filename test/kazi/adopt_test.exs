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
