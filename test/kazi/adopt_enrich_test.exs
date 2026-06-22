defmodule Kazi.AdoptEnrichTest do
  # T5.4: optional harness ENRICHMENT, off by default (ADR-0013 §4, UC-023).
  # Hermetic — the harness is driven through the SAME injectable seam everything
  # else uses (`Kazi.HarnessAdapter.run/3`); tests inject a STUB adapter, so no
  # real `claude`, no network. Determinism of the off-path is asserted directly.
  use ExUnit.Case, async: true

  alias Kazi.Adopt
  alias Kazi.Goal
  alias Kazi.Goal.Loader

  @fixtures Path.expand("../fixtures/adopt", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  # Self-contained in-memory file_reader seam (the `{module, state}` tuple
  # Kazi.Adopt threads through regular?/2 and read/2). Defined locally rather
  # than reaching into another test file's module, so test-file load order never
  # affects this suite.
  defmodule InMemoryReader do
    @moduledoc false

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

  # A STUB harness implementing the same behaviour the real adapter implements
  # (Kazi.HarnessAdapter). It records nothing and shells out to nothing; it just
  # returns a canned proposal of live predicates under the `:result` field, the
  # shape the `claude --output-format json` envelope carries. No network, no
  # subprocess — purely hermetic.
  defmodule StubHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result:
           ~s({"predicates":[) <>
             ~s({"id":"health","provider":"http_probe","description":"GET /healthz is 200",) <>
             ~s("url":"http://localhost:8080/healthz","expect_status":200},) <>
             ~s({"id":"home","provider":"browser","description":"home page renders",) <>
             ~s("url":"http://localhost:8080/"}]})
       }}
    end
  end

  # A stub harness that hands back an already-decoded proposal map (the adapter
  # may pre-decode) — exercises the map payload path, not the JSON-string path.
  defmodule DecodedHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         proposal: %{
           "predicates" => [
             %{"id" => "probe", "provider" => "http_probe", "url" => "http://x/health"}
           ]
         }
       }}
    end
  end

  # A stub harness that proposes a non-live (test_runner) predicate and a
  # malformed one — neither is loadable as a live enrichment, so both are dropped.
  defmodule NoisyHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         result:
           ~s({"predicates":[) <>
             ~s({"id":"tests","provider":"test_runner","cmd":"go"},) <>
             ~s({"provider":"http_probe"},) <>
             ~s({"id":"ok","provider":"http_probe","url":"http://x/ok"}]})
       }}
    end
  end

  # A stub harness that fails — enrichment is best-effort, so a harness error must
  # collapse to no proposals rather than failing the adoption.
  defmodule FailingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts), do: {:error, :unavailable}
  end

  describe "adopt/2 with enrichment OFF (the default)" do
    test "output is the deterministic detection only, with an empty :proposed" do
      assert {:ok, %{stack: :go, predicate: predicate, proposed: []}} =
               Adopt.adopt(fixture("go"))

      assert predicate["provider"] == "test_runner"
    end

    test "off-path equals the pure detect/1 result, plus proposed: []" do
      {:ok, detection} = Adopt.detect(fixture("go"))
      {:ok, adopted} = Adopt.adopt(fixture("go"))

      assert Map.delete(adopted, :proposed) == detection
      assert adopted.proposed == []
    end

    test "passing a harness but no enrich flag still does NOT drive it" do
      # FailingHarness would surface no error and proposed stays [] because the
      # harness is never called when enrichment is off.
      assert {:ok, %{proposed: []}} = Adopt.adopt(fixture("go"), harness: FailingHarness)
    end

    test "the off-path is deterministic across runs (byte-identical)" do
      assert Adopt.adopt(fixture("go")) == Adopt.adopt(fixture("go"))

      assert Adopt.adopt(fixture("node-with-test")) ==
               Adopt.adopt(fixture("node-with-test"))
    end

    test "no-detection is unchanged by the enrichment wrapper" do
      assert {:error, :no_stack_detected} = Adopt.adopt(fixture("unknown"))
    end
  end

  describe "adopt/2 with enrichment ON via a STUB harness" do
    test "proposed live predicates are merged into the result" do
      assert {:ok, %{stack: :go, predicate: predicate, proposed: proposed}} =
               Adopt.adopt(fixture("go"), enrich: true, harness: StubHarness)

      # The deterministic test_runner predicate is untouched.
      assert predicate["provider"] == "test_runner"

      providers = Enum.map(proposed, & &1["provider"])
      assert "http_probe" in providers
      assert "browser" in providers
      assert length(proposed) == 2
    end

    test "every proposed predicate round-trips through Kazi.Goal.Loader" do
      {:ok, %{predicate: detected, proposed: proposed}} =
        Adopt.adopt(fixture("go"), enrich: true, harness: StubHarness)

      goal_map = %{"id" => "adopt-enriched", "predicate" => [detected | proposed]}

      assert {:ok, %Goal{} = goal} = Loader.from_map(goal_map)
      kinds = Enum.map(goal.predicates, & &1.kind)
      assert :tests in kinds
      assert :http_probe in kinds
      assert :browser in kinds
    end

    test "an already-decoded proposal map is accepted too" do
      assert {:ok, %{proposed: [probe]}} =
               Adopt.adopt(fixture("go"), enrich: true, harness: DecodedHarness)

      assert probe["provider"] == "http_probe"
      assert probe["id"] == "probe"
    end

    test "non-live and malformed proposals are dropped; only loadable live kept" do
      assert {:ok, %{proposed: proposed}} =
               Adopt.adopt(fixture("go"), enrich: true, harness: NoisyHarness)

      assert [%{"id" => "ok", "provider" => "http_probe"}] = proposed
    end

    test "enrich/3 returns the proposed predicate list directly" do
      {:ok, detection} = Adopt.detect(fixture("go"))

      proposed = Adopt.enrich(fixture("go"), detection, enrich: true, harness: StubHarness)
      assert length(proposed) == 2
    end
  end

  describe "adopt/2 enrichment is best-effort and hermetic" do
    test "a harness error collapses to proposed: [], adoption still stands" do
      assert {:ok, %{stack: :go, predicate: predicate, proposed: []}} =
               Adopt.adopt(fixture("go"), enrich: true, harness: FailingHarness)

      assert predicate["provider"] == "test_runner"
    end

    test "enrichment composes onto an injected in-memory reader (no disk, no net)" do
      reader = InMemoryReader.new(%{"go.mod" => "module example.com/app\n"})

      assert {:ok, %{stack: :go, proposed: proposed}} =
               Adopt.adopt("/virtual/repo",
                 file_reader: reader,
                 enrich: true,
                 harness: StubHarness
               )

      assert length(proposed) == 2
    end
  end

  describe "enrich_prompt/1 is pure and total" do
    test "names the detected stack and asks only for live providers" do
      prompt = Adopt.enrich_prompt(%{stack: :go, predicate: %{}})

      assert prompt =~ "go"
      assert prompt =~ "http_probe"
      assert prompt =~ "browser"
      # It explicitly tells the harness NOT to propose a test_runner predicate.
      assert prompt =~ "Do NOT propose a test_runner"
    end
  end
end
