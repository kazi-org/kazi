defmodule Kazi.AdoptRegistryTest do
  # T7.1 / T7.2: the capability-registry adapter (ADR-0015). Parse a JSON
  # registry into normalized capabilities, then map them to a goal SET. Hermetic
  # — reads the committed fixture and a self-contained in-memory reader; no
  # network, no shelling out. The in-memory reader is defined LOCALLY (not
  # reaching into another test file's module), so load order never matters.
  use ExUnit.Case, async: true

  alias Kazi.Adopt.Registry
  alias Kazi.Goal
  alias Kazi.Goal.Loader

  @fixture Path.expand("../fixtures/capabilities.json", __DIR__)

  # A self-contained in-memory file_reader seam (the `{module, state}` tuple the
  # registry threads through read/2). The registry path IS the file (no marker
  # join), so the state map is keyed by full path and read/2 looks it up directly.
  defmodule InMemoryReader do
    @moduledoc false

    def new(files) when is_map(files), do: {__MODULE__, files}

    def read(files, path) do
      case Map.fetch(files, path) do
        {:ok, contents} -> {:ok, contents}
        :error -> {:error, :enoent}
      end
    end
  end

  describe "parse/2 happy path" do
    test "parses the fixture registry into normalized capabilities, sorted by id" do
      assert {:ok, caps} = Registry.parse(@fixture)

      assert Enum.map(caps, & &1.id) == [
               "auth.password-reset",
               "billing.invoice-pdf",
               "search.autocomplete"
             ]

      auth = Enum.find(caps, &(&1.id == "auth.password-reset"))
      assert auth.name == "User can reset their password"
      assert auth.scope == "auth"

      assert [%{cmd: "go", args: ["test", "./auth/...", "-run", "TestPasswordReset"]}] =
               auth.bindings
    end

    test "a capability with a `tests` array carries multiple bindings" do
      assert {:ok, caps} = Registry.parse(@fixture)
      billing = Enum.find(caps, &(&1.id == "billing.invoice-pdf"))
      assert length(billing.bindings) == 2
      assert Enum.map(billing.bindings, & &1.cmd) == ["go", "npm"]
    end

    test "a capability with NO binding is a gap (empty bindings, no scope)" do
      assert {:ok, caps} = Registry.parse(@fixture)
      search = Enum.find(caps, &(&1.id == "search.autocomplete"))
      assert search.bindings == []
      assert search.scope == nil
    end

    test "reads through an injected in-memory reader (no disk)" do
      json = ~s({"capabilities":[{"id":"a","name":"A"}]})
      reader = InMemoryReader.new(%{"/virtual/registry.json" => json})

      assert {:ok, [cap]} = Registry.parse("/virtual/registry.json", file_reader: reader)
      assert cap.id == "a"
    end

    test "is deterministic across runs" do
      assert Registry.parse(@fixture) == Registry.parse(@fixture)
    end
  end

  describe "parse/2 prose rejection (ADR-0015 §3)" do
    test "a .md path is rejected before any read, naming it a generated view" do
      assert {:error, reason} = Registry.parse("docs/capabilities.md")
      assert reason =~ "generated view" or reason =~ "GENERATED VIEW"
      assert reason =~ "JSON"
    end

    test "the .md guard is case-insensitive" do
      assert {:error, _} = Registry.parse("USECASES.MD")
    end
  end

  describe "parse/2 error paths" do
    test "malformed JSON yields a clear error" do
      reader = InMemoryReader.new(%{"/x.json" => "{not json"})
      assert {:error, reason} = Registry.parse("/x.json", file_reader: reader)
      assert reason =~ "malformed JSON"
    end

    test "an empty capabilities array is rejected" do
      reader = InMemoryReader.new(%{"/x.json" => ~s({"capabilities":[]})})
      assert {:error, reason} = Registry.parse("/x.json", file_reader: reader)
      assert reason =~ "empty"
    end

    test "a missing capabilities array is rejected" do
      reader = InMemoryReader.new(%{"/x.json" => ~s({"version":1})})
      assert {:error, reason} = Registry.parse("/x.json", file_reader: reader)
      assert reason =~ "missing"
    end

    test "a capability missing id is rejected" do
      reader = InMemoryReader.new(%{"/x.json" => ~s({"capabilities":[{"name":"X"}]})})
      assert {:error, reason} = Registry.parse("/x.json", file_reader: reader)
      assert reason =~ "id"
    end

    test "a capability missing name is rejected" do
      reader = InMemoryReader.new(%{"/x.json" => ~s({"capabilities":[{"id":"x"}]})})
      assert {:error, reason} = Registry.parse("/x.json", file_reader: reader)
      assert reason =~ "name"
    end

    test "a non-object JSON root is rejected" do
      reader = InMemoryReader.new(%{"/x.json" => "[1,2,3]"})
      assert {:error, reason} = Registry.parse("/x.json", file_reader: reader)
      assert reason =~ "capabilities"
    end

    test "an unreadable file yields a clear error" do
      reader = InMemoryReader.new(%{})
      assert {:error, reason} = Registry.parse("/missing.json", file_reader: reader)
      assert reason =~ "cannot read registry"
    end
  end

  describe "to_goal_set/2 mapping (T7.2)" do
    test "maps each capability to one goal_plan, ordered by id" do
      {:ok, caps} = Registry.parse(@fixture)
      plans = Registry.to_goal_set(caps)

      assert Enum.map(plans, & &1.id) == [
               "auth.password-reset",
               "billing.invoice-pdf",
               "search.autocomplete"
             ]
    end

    test "a declared binding becomes a test_runner acceptance predicate naming the command" do
      {:ok, caps} = Registry.parse(@fixture)
      plans = Registry.to_goal_set(caps)
      auth = Enum.find(plans, &(&1.id == "auth.password-reset"))

      assert [pred] = auth.goal_map["predicate"]
      assert pred["provider"] == "test_runner"
      assert pred["acceptance"] == true
      assert pred["cmd"] == "go"
      assert pred["args"] == ["test", "./auth/...", "-run", "TestPasswordReset"]
    end

    test "multiple bindings become indexed acceptance predicates" do
      {:ok, caps} = Registry.parse(@fixture)
      plans = Registry.to_goal_set(caps)
      billing = Enum.find(plans, &(&1.id == "billing.invoice-pdf"))

      ids = Enum.map(billing.goal_map["predicate"], & &1["id"])
      assert ids == ["acceptance-1", "acceptance-2"]
      cmds = Enum.map(billing.goal_map["predicate"], & &1["cmd"])
      assert cmds == ["go", "npm"]
    end

    test "a GAP capability emits no invented command (a gap-marker, TODO via writer)" do
      {:ok, caps} = Registry.parse(@fixture)
      plans = Registry.to_goal_set(caps)
      search = Enum.find(plans, &(&1.id == "search.autocomplete"))

      assert [gap] = search.goal_map["predicate"]
      # The gap-marker is a guard running a no-op `true` — NOT an invented test
      # command. The real binding is left to the writer's commented TODO / --enrich.
      assert gap["guard"] == true
      assert gap["cmd"] == "true"
      assert gap["description"] =~ "GAP"
    end

    test "is deterministic across runs" do
      {:ok, caps} = Registry.parse(@fixture)
      assert Registry.to_goal_set(caps) == Registry.to_goal_set(caps)
    end
  end

  describe "every goal_map round-trips through Kazi.Goal.Loader" do
    test "all generated goals load cleanly (declared bindings and gaps)" do
      {:ok, caps} = Registry.parse(@fixture)
      plans = Registry.to_goal_set(caps)

      for %{goal_map: goal_map} <- plans do
        assert {:ok, %Goal{}} = Loader.from_map(goal_map)
      end
    end

    test "the rendered TOML decodes and loads (the full writer path, incl. live scaffold)" do
      {:ok, caps} = Registry.parse(@fixture)
      plans = Registry.to_goal_set(caps)

      for plan <- plans do
        toml = Registry.render(plan)
        # The commented live-predicate scaffold is present in every file.
        assert toml =~ "# [[predicate]]"
        assert toml =~ ~s(# provider = "http_probe")

        assert {:ok, decoded} = Toml.decode(toml)
        assert {:ok, %Goal{}} = Loader.from_map(decoded)
      end
    end
  end

  describe "to_goal_set/2 enrichment is OFF by default (ADR-0015 §3)" do
    # A stub harness that, if ever driven, proposes a live predicate. With enrich
    # OFF it must never be called: a gap stays a gap-marker.
    defmodule StubHarness do
      @behaviour Kazi.HarnessAdapter

      @impl true
      def run(_prompt, _workspace, _opts) do
        {:ok,
         %{
           result: ~s({"predicates":[{"id":"probe","provider":"http_probe","url":"http://x/ok"}]})
         }}
      end
    end

    test "default-off: a gap stays a gap-marker even with a harness present" do
      {:ok, caps} = Registry.parse(@fixture)
      # Pass a harness but no enrich flag — it must NOT be driven.
      plans = Registry.to_goal_set(caps, harness: StubHarness)
      search = Enum.find(plans, &(&1.id == "search.autocomplete"))
      assert [gap] = search.goal_map["predicate"]
      assert gap["id"] == "acceptance-gap"
    end

    test "enrich: true only fills gaps via the harness; declared bindings untouched" do
      {:ok, caps} = Registry.parse(@fixture)

      plans =
        Registry.to_goal_set(caps,
          enrich: true,
          harness: StubHarness,
          workspace: "/virtual/repo"
        )

      # The gap is now filled by a harness-proposed acceptance predicate.
      search = Enum.find(plans, &(&1.id == "search.autocomplete"))
      assert [filled] = search.goal_map["predicate"]
      assert filled["provider"] == "http_probe"
      assert filled["acceptance"] == true

      # A capability with a DECLARED binding is unchanged by enrichment.
      auth = Enum.find(plans, &(&1.id == "auth.password-reset"))
      assert [pred] = auth.goal_map["predicate"]
      assert pred["cmd"] == "go"
      assert pred["provider"] == "test_runner"

      # Every enriched goal still round-trips.
      for %{goal_map: gm} <- plans, do: assert({:ok, %Goal{}} = Loader.from_map(gm))
    end
  end
end
