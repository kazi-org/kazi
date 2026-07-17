defmodule Kazi.Loop.ContextStoreTest do
  @moduledoc """
  T35.4: with a context store configured, an oversized failing-evidence artifact is
  indexed (not inlined), the dispatch prompt carries a compact reference plus
  budget-fitted snippets, and secrets are redacted on the way out. Sub-threshold
  evidence inlines as before.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateResult}
  alias Kazi.ContextStore.GistCLI

  @fake Path.expand("../../support/fake_gist.sh", __DIR__)
  @secret "AKIAIOSFODNN7EXAMPLE"

  # A provider that fails forever with a fixed evidence blob read from goal metadata.
  defmodule BigFailProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, context),
      do: PredicateResult.fail(%{id: id, output: context.goal.metadata.evidence})
  end

  # Records each dispatch prompt to the collector and reports success.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:dispatched, prompt})
      {:ok, %{output: "ok", cost: %{tokens: 1}}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{}, _context), do: {:ok, %{}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{}, _context), do: {:ok, %{}}
  end

  defp run_one_dispatch(evidence, adapter_extra) do
    store = Path.join(System.tmp_dir!(), "loop-gist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(store)
    on_exit(fn -> File.rm_rf(store) end)

    goal =
      Goal.new("loop-test",
        predicates: [Predicate.new(:code, :tests)],
        # T44.4: disable the (orthogonal) process contract so this test pins the
        # CONTEXT-STORE evidence-compression prompt behavior in isolation.
        conventions: %{process_contract: false, extra_rules: []},
        metadata: %{collector: self(), evidence: evidence}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: BigFailProvider},
        harness: RecordingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        adapter_opts: [collector: self()] ++ adapter_extra.(store),
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    assert_receive {:dispatched, prompt}, 2_000
    Kazi.Loop.stop(loop)
    {prompt, store}
  end

  describe "oversized evidence is compressed into the store" do
    setup do
      big =
        "DATABASE_URL=postgres://app:#{@secret}@db/prod\n" <>
          String.duplicate("verbose failing test log line with detail\n", 200)

      # sanity: the rendered artifact (same inspect opts the loop uses) must exceed
      # the 5 KB threshold.
      rendered =
        inspect(%{code: %{id: :code, output: big}}, limit: :infinity, printable_limit: :infinity)

      assert byte_size(rendered) > 5_120
      {:ok, big: big}
    end

    test "the evidence slot holds the indexed label, not the raw bytes", %{big: big} do
      {prompt, _store} =
        run_one_dispatch(big, fn s ->
          [
            context_store: {GistCLI, [gist_bin: @fake, env: [{"FAKE_GIST_STORE", s}]]},
            context_budget: 400
          ]
        end)

      assert prompt =~ "[indexed kazi:run:loop-test:iter:"
      # the full raw artifact is NOT inlined verbatim
      refute prompt =~ String.duplicate("verbose failing test log line with detail\n", 200)
      # compression actually shrank it well below the raw size
      assert byte_size(prompt) < byte_size(big)
    end

    test "a budget-fitted store section is injected", %{big: big} do
      {prompt, _store} =
        run_one_dispatch(big, fn s ->
          [
            context_store: {GistCLI, [gist_bin: @fake, env: [{"FAKE_GIST_STORE", s}]]},
            context_budget: 400
          ]
        end)

      assert prompt =~ "## Indexed evidence (context store)"
      # T35.9: the inner-harness contract rule travels with the snippets.
      assert prompt =~ "request a targeted source/query"
      assert prompt =~ "do not ask for whole logs or whole docs"
    end

    test "the secret is redacted everywhere it could egress", %{big: big} do
      {prompt, store} =
        run_one_dispatch(big, fn s ->
          [
            context_store: {GistCLI, [gist_bin: @fake, env: [{"FAKE_GIST_STORE", s}]]},
            context_budget: 400
          ]
        end)

      refute prompt =~ @secret
      stored = File.read!(Path.join(store, "content.dat"))
      refute stored =~ @secret
      assert stored =~ "[REDACTED]"
    end
  end

  describe "sub-threshold evidence inlines as before" do
    test "small evidence is inlined and no store section is added" do
      small = "1 test, 1 failure"

      {prompt, _store} =
        run_one_dispatch(small, fn s ->
          [
            context_store: {GistCLI, [gist_bin: @fake, env: [{"FAKE_GIST_STORE", s}]]},
            context_budget: 400
          ]
        end)

      assert prompt =~ "1 failure"
      refute prompt =~ "## Indexed evidence (context store)"
      refute prompt =~ "[indexed kazi:run:"
    end
  end

  describe "default path (no store) is unchanged" do
    test "without a context_store the evidence inlines and nothing is indexed" do
      big = String.duplicate("verbose failing test log line\n", 300)

      {prompt, _store} = run_one_dispatch(big, fn _s -> [] end)

      refute prompt =~ "## Indexed evidence (context store)"
      refute prompt =~ "[indexed kazi:run:"
      assert prompt =~ "verbose failing test log line"
    end
  end
end
