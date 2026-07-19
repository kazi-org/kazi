defmodule Kazi.Harness.ClaudeAdapterTest do
  # Not async: the config-fallback and non-zero-exit tests mutate process-global
  # state (Application env, OS env). Per-test isolation otherwise via unique tmp
  # workspaces.
  use ExUnit.Case, async: false

  alias Kazi.Context
  alias Kazi.Context.StaticGraphSource
  alias Kazi.Harness.ClaudeAdapter
  alias Kazi.PredicateResult

  @stub Path.expand("../../support/stub_claude.sh", __DIR__)
  # T4.1: a stub emitting a representative `claude -p --output-format json`
  # envelope, and one whose JSON is deliberately malformed (degradation path).
  @json_stub Path.expand("../../support/stub_claude_json.sh", __DIR__)
  @bad_json_stub Path.expand("../../support/stub_claude_bad_json.sh", __DIR__)
  # T4.8: a stub echoing every argv element so a test can assert the claw-code
  # hygiene flags (per-dispatch budget ceiling + minimal tool/permission set)
  # reached the harness over the real System.cmd boundary.
  @args_stub Path.expand("../../support/stub_claude_args.sh", __DIR__)

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "kazi-claude-adapter-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  describe "build_prompt/2 (pure prompt construction)" do
    test "seeds the work item plus failing-predicate evidence" do
      failing = [
        {:unit, PredicateResult.fail(%{output: "1 test, 1 failure", exit: 1})},
        {:live, PredicateResult.fail(%{http_status: 500, url: "https://x/health"})}
      ]

      prompt = ClaudeAdapter.build_prompt("Make the suite green", failing)

      assert prompt =~ "Make the suite green"
      assert prompt =~ "Failing predicate: unit"
      assert prompt =~ "Failing predicate: live"
      assert prompt =~ "1 test, 1 failure"
      assert prompt =~ "http_status: 500"
      # Guards against the agent "passing" a predicate by deleting the check.
      assert prompt =~ "not the checks themselves"
    end

    test "handles a failing predicate with no evidence" do
      prompt = ClaudeAdapter.build_prompt("fix it", [{:unit, PredicateResult.fail()}])
      assert prompt =~ "(no evidence captured)"
    end

    test "renders just the work item when nothing is failing" do
      prompt = ClaudeAdapter.build_prompt("nothing failing", [])
      assert prompt =~ "nothing failing"
      refute prompt =~ "Failing predicate"
    end
  end

  describe "build_prompt/3 (stable orientation prefix, T4.3)" do
    # A hermetic graph source keyed off the workspace, so the same (workspace,
    # failing) always surveys the same structure — the stand-in for a fixed
    # (git-sha, failing-set) the prompt cache hits on.
    @workspace "/fixture/ws"

    defp orientation_source do
      StaticGraphSource.new(
        origin: :graph,
        files: ["lib/target.ex", "lib/helper.ex"],
        symbols: [{"build/1", "lib/target.ex", [callers: ["caller/0"]]}],
        test_sources: [{"test/target_test.exs", [source: "assert Target.build(1)"]}]
      )
    end

    defp failing_unit do
      [{:unit, PredicateResult.fail(%{output: "boom in lib/target.ex:42"})}]
    end

    test "with no context opt, build_prompt/3 is byte-identical to build_prompt/2" do
      failing = failing_unit()

      assert ClaudeAdapter.build_prompt("fix it", failing, []) ==
               ClaudeAdapter.build_prompt("fix it", failing)
    end

    test "prepends the rendered orientation pack as the prompt head (:workspace)" do
      prompt =
        ClaudeAdapter.build_prompt("fix it", failing_unit(),
          workspace: @workspace,
          graph_source: orientation_source()
        )

      # The orientation head appears, carrying the impacted file/symbol map…
      assert prompt =~ "# Orientation"
      assert prompt =~ "lib/target.ex"
      assert prompt =~ "build/1"
      # …and the prefix sits in FRONT of the failing-evidence body.
      assert orientation_index(prompt) < evidence_index(prompt)
    end

    test "accepts a pre-built :context_pack, rendering it verbatim as the prefix" do
      pack =
        Context.orientation_pack(failing_unit(), @workspace, graph_source: orientation_source())

      prompt = ClaudeAdapter.build_prompt("fix it", failing_unit(), context_pack: pack)

      assert prompt =~ Context.render(pack)
      assert orientation_index(prompt) < evidence_index(prompt)
    end

    test ":context_pack takes precedence over :workspace" do
      pack = %Kazi.Context.Pack{
        origin: :repo_map,
        files: [Kazi.Context.FileRef.new("lib/only.ex")]
      }

      prompt =
        ClaudeAdapter.build_prompt("fix it", failing_unit(),
          context_pack: pack,
          workspace: @workspace,
          graph_source: orientation_source()
        )

      # The given pack is what renders; the :workspace-built pack's "## Impacted
      # symbols" / "build/1" content must NOT leak into the orientation head when a
      # pack is supplied. (The evidence body legitimately mentions lib/target.ex,
      # so assert on the prefix region, not the whole prompt.)
      assert prefix_of(prompt) =~ "lib/only.ex"
      refute prefix_of(prompt) =~ "build/1"
      refute prefix_of(prompt) =~ "Impacted symbols"
    end

    test "the orientation prefix is byte-identical across iterations for the same (workspace, failing-set)" do
      # Two separate dispatches for the same SHA-equivalent inputs: the cacheable
      # head must be byte-for-byte identical so the prompt cache hits (ADR-0010).
      opts = [workspace: @workspace, graph_source: orientation_source()]

      first = ClaudeAdapter.build_prompt("fix it", failing_unit(), opts)
      second = ClaudeAdapter.build_prompt("fix it", failing_unit(), opts)

      assert prefix_of(first) == prefix_of(second)
      assert first == second
    end

    test "the evidence section is unchanged versus the no-prefix path" do
      failing = failing_unit()

      with_prefix =
        ClaudeAdapter.build_prompt("fix it", failing,
          workspace: @workspace,
          graph_source: orientation_source()
        )

      no_prefix = ClaudeAdapter.build_prompt("fix it", failing)

      # The volatile tail (work item + failing-evidence) is byte-identical to the
      # /2 output; only the orientation head is prepended.
      assert String.ends_with?(with_prefix, no_prefix)
      assert evidence_body(with_prefix) == no_prefix
    end

    test "an empty pack still yields a stable orientation marker (sparse workspace)" do
      empty = %Kazi.Context.Pack{origin: :repo_map, files: [], symbols: [], test_sources: []}

      prompt = ClaudeAdapter.build_prompt("fix it", failing_unit(), context_pack: empty)

      assert prompt =~ "# Orientation"
      assert orientation_index(prompt) < evidence_index(prompt)
    end

    # --- helpers: locate / split the two prompt regions -----------------------

    @evidence_marker "The following predicates are currently failing."

    defp orientation_index(prompt) do
      {idx, _} = :binary.match(prompt, "# Orientation")
      idx
    end

    defp evidence_index(prompt) do
      {idx, _} = :binary.match(prompt, @evidence_marker)
      idx
    end

    # The work-item + evidence tail of a prefixed prompt: everything from the work
    # item onward. The prefix is joined to the body with "\n\n"; the body starts at
    # the work item, which precedes the evidence marker on its own lines.
    defp evidence_body(prompt) do
      {idx, _} = :binary.match(prompt, "fix it\n\n" <> @evidence_marker)
      binary_part(prompt, idx, byte_size(prompt) - idx)
    end

    defp prefix_of(prompt) do
      {idx, _} = :binary.match(prompt, "fix it\n\n" <> @evidence_marker)
      binary_part(prompt, 0, idx)
    end
  end

  describe "build_prompt/3 optional retrieval section (T4.9a, ADR-0012)" do
    alias Kazi.Retrieval.StaticRetriever

    @retrieval_heading "## Relevant prior context (retrieved)"

    defp failing_retr do
      [{:unit, PredicateResult.fail(%{output: "boom in lib/target.ex:42"})}]
    end

    test "with retrieval OFF (no :retriever), build_prompt/3 is byte-identical to /2" do
      failing = failing_retr()

      # The whole point of ADR-0012: the default path must not change a byte.
      assert ClaudeAdapter.build_prompt("fix it", failing, []) ==
               ClaudeAdapter.build_prompt("fix it", failing)
    end

    test "with retrieval OFF, no retrieval section is emitted" do
      prompt = ClaudeAdapter.build_prompt("fix it", failing_retr(), [])
      refute prompt =~ @retrieval_heading
    end

    test "an empty retriever result emits NOTHING (byte-identical to off)" do
      empty = StaticRetriever.new(snippets: [])

      with_empty = ClaudeAdapter.build_prompt("fix it", failing_retr(), retriever: empty)
      off = ClaudeAdapter.build_prompt("fix it", failing_retr())

      assert with_empty == off
      refute with_empty =~ @retrieval_heading
    end

    test "an injected retriever renders snippets in a dedicated section" do
      retriever =
        StaticRetriever.new(
          snippets: [
            {"def build(x), do: x + 1", source: "lib/target.ex:42"},
            "a sourceless hint"
          ]
        )

      prompt = ClaudeAdapter.build_prompt("fix it", failing_retr(), retriever: retriever)

      assert prompt =~ @retrieval_heading
      assert prompt =~ "lib/target.ex:42"
      assert prompt =~ "def build(x), do: x + 1"
      assert prompt =~ "a sourceless hint"
    end

    test "the retrieval section sits AFTER the orientation prefix and the evidence body" do
      retriever = StaticRetriever.new(snippets: [{"snippet body", source: "lib/x.ex"}])

      prompt =
        ClaudeAdapter.build_prompt("fix it", failing_retr(),
          workspace: "/fixture/ws",
          graph_source: StaticGraphSource.new(origin: :graph, files: ["lib/target.ex"]),
          retriever: retriever
        )

      {orient, _} = :binary.match(prompt, "# Orientation")
      {evidence, _} = :binary.match(prompt, "The following predicates are currently failing.")
      {retr, _} = :binary.match(prompt, @retrieval_heading)

      # Orientation prefix < failing-evidence body < retrieval augmentation.
      assert orient < evidence
      assert evidence < retr
    end

    test "is deterministic given a fixed retriever" do
      retriever = StaticRetriever.new(snippets: [{"x", source: "lib/a.ex"}, "y"])
      opts = [retriever: retriever]

      first = ClaudeAdapter.build_prompt("fix it", failing_retr(), opts)
      second = ClaudeAdapter.build_prompt("fix it", failing_retr(), opts)

      assert first == second
    end

    test "the retrieval section is purely additive — the pre-retrieval prompt is a prefix of it" do
      retriever = StaticRetriever.new(snippets: [{"hint", source: "lib/a.ex"}])

      off = ClaudeAdapter.build_prompt("fix it", failing_retr())
      on = ClaudeAdapter.build_prompt("fix it", failing_retr(), retriever: retriever)

      # Retrieval only appends; everything before it is byte-for-byte the off path.
      assert String.starts_with?(on, off)
    end
  end

  describe "run/3 against a stub binary (real subprocess boundary)" do
    test "runs the harness in the target workspace so edits land in place", %{
      workspace: workspace
    } do
      prompt =
        ClaudeAdapter.build_prompt("fix unit", [
          {:unit, PredicateResult.fail(%{output: "assertion failed: expected 2, got 3"})}
        ])

      assert {:ok, result} = ClaudeAdapter.run(prompt, workspace, command: @stub)

      # The stub wrote a marker into its cwd — proving cd: workspace took effect.
      assert File.exists?(Path.join(workspace, "stub_edit.txt"))
      assert File.read!(Path.join(workspace, "stub_edit.txt")) == "edited-by-stub\n"

      # Output is captured; the stub echoes the cwd and the prompt it received.
      assert result.output =~ "stub ran in:"
      assert result.output =~ workspace
      assert result.output =~ "assertion failed: expected 2, got 3"
      assert result.exit == 0
      assert result.command == @stub
      assert result.workspace == workspace
    end

    test "captures a non-zero exit from the harness", %{workspace: workspace} do
      System.put_env("STUB_EXIT", "7")
      on_exit(fn -> System.delete_env("STUB_EXIT") end)

      assert {:ok, result} = ClaudeAdapter.run("do work", workspace, command: @stub)
      assert result.exit == 7
    end

    test "returns :empty_prompt without invoking the harness", %{workspace: workspace} do
      assert {:error, :empty_prompt} = ClaudeAdapter.run("", workspace, command: @stub)
      refute File.exists?(Path.join(workspace, "stub_edit.txt"))
    end

    test "reports a missing binary as an error, not failing work", %{workspace: workspace} do
      assert {:error, {:command_not_found, "kazi-no-such-binary"}} =
               ClaudeAdapter.run("do work", workspace, command: "kazi-no-such-binary")
    end

    test "falls back to app config for the command", %{workspace: workspace} do
      Application.put_env(:kazi, :harness_command, @stub)
      on_exit(fn -> Application.delete_env(:kazi, :harness_command) end)

      assert {:ok, result} = ClaudeAdapter.run("do work", workspace, [])
      assert result.command == @stub
      assert File.exists?(Path.join(workspace, "stub_edit.txt"))
    end
  end

  describe "run/3 JSON envelope parsing (T4.1, UC-009/UC-022)" do
    test "parses token usage, cost, result text, and touched working set", %{
      workspace: workspace
    } do
      assert {:ok, result} = ClaudeAdapter.run("fix it", workspace, command: @json_stub)

      # Back-compat: the raw keys are still present alongside the structured ones.
      assert result.command == @json_stub
      assert result.workspace == workspace
      assert result.exit == 0
      assert is_binary(result.output)

      # The agent's final result text.
      assert result.result == "Made the failing unit test pass."

      # Total tokens = input(100) + output(250) + cache_read(5000) + cache_create(0).
      assert result.tokens == 5350
      # The dollar cost surfaces too.
      assert result.cost_usd == 0.0123
      # The touched working set the harness reported.
      assert result.touched == ["lib/app/widget.ex", "test/app/widget_test.exs"]

      # The budget-consumable shape the loop's T1.4 guard reads (cost.tokens).
      assert result.cost == %{tokens: 5350}
    end

    test "token total honors per-component env overrides on the stub", %{workspace: workspace} do
      System.put_env("STUB_INPUT_TOKENS", "10")
      System.put_env("STUB_OUTPUT_TOKENS", "20")
      System.put_env("STUB_CACHE_READ_TOKENS", "0")
      System.put_env("STUB_CACHE_CREATION_TOKENS", "5")

      on_exit(fn ->
        ~w(STUB_INPUT_TOKENS STUB_OUTPUT_TOKENS STUB_CACHE_READ_TOKENS STUB_CACHE_CREATION_TOKENS)
        |> Enum.each(&System.delete_env/1)
      end)

      assert {:ok, result} = ClaudeAdapter.run("fix it", workspace, command: @json_stub)
      assert result.tokens == 35
      assert result.cost == %{tokens: 35}
    end

    test "degrades gracefully on malformed JSON: base keys only, no crash", %{
      workspace: workspace
    } do
      assert {:ok, result} = ClaudeAdapter.run("fix it", workspace, command: @bad_json_stub)

      # The run still succeeded and the base keys are intact.
      assert result.exit == 0
      assert result.command == @bad_json_stub
      assert result.workspace == workspace
      assert is_binary(result.output)
      assert File.exists?(Path.join(workspace, "stub_edit.txt"))

      # No structured keys were fabricated from un-parseable output.
      refute Map.has_key?(result, :tokens)
      refute Map.has_key?(result, :cost)
      refute Map.has_key?(result, :cost_usd)
      refute Map.has_key?(result, :result)
      refute Map.has_key?(result, :touched)
    end

    test "a plaintext (non-JSON) harness keeps the pre-T4.1 result shape", %{
      workspace: workspace
    } do
      # The original plaintext stub emits no JSON — the adapter must degrade to
      # exactly the back-compat base map (no structured keys), proving the JSON
      # path is purely additive.
      assert {:ok, result} = ClaudeAdapter.run("do work", workspace, command: @stub)

      assert result.output =~ "stub ran in:"
      refute Map.has_key?(result, :tokens)
      refute Map.has_key?(result, :cost)
    end
  end

  describe "truncate_evidence/2 (pure, T4.8, UC-009/UC-022)" do
    test "returns input verbatim when within the byte budget" do
      assert ClaudeAdapter.truncate_evidence("short evidence", max_bytes: 1_024) ==
               "short evidence"
    end

    test "returns input verbatim when exactly at the budget" do
      blob = String.duplicate("a", 64)
      assert ClaudeAdapter.truncate_evidence(blob, max_bytes: 64) == blob
    end

    test "truncates oversized evidence to the byte budget with a marker" do
      big = String.duplicate("x", 10_000)
      out = ClaudeAdapter.truncate_evidence(big, max_bytes: 200)

      assert byte_size(out) <= 200
      assert out =~ "…truncated…"
    end

    test "keeps a head and a tail around the marker (both signals survive)" do
      # A distinctive lead-in (the failure) and tail-end (its resolution context)
      # must both survive a head+tail truncation.
      body = String.duplicate("-", 5_000)
      evidence = "FAILURE_HEAD" <> body <> "RESOLUTION_TAIL"

      out = ClaudeAdapter.truncate_evidence(evidence, max_bytes: 200)

      assert out =~ "FAILURE_HEAD"
      assert out =~ "RESOLUTION_TAIL"
      assert out =~ "…truncated…"
      assert byte_size(out) <= 200
    end

    test "defaults to the module's evidence budget when no max_bytes given" do
      big = String.duplicate("y", 100_000)
      out = ClaudeAdapter.truncate_evidence(big)

      # Bounded well below the input, and still legible as a truncation.
      assert byte_size(out) < byte_size(big)
      assert byte_size(out) <= 8_192
      assert out =~ "…truncated…"
    end

    test "degrades to a head-only cut when the budget is too small for the marker" do
      out = ClaudeAdapter.truncate_evidence(String.duplicate("z", 1_000), max_bytes: 4)

      # Never larger than asked; no room for the marker so it is omitted.
      assert byte_size(out) <= 4
      refute out =~ "…truncated…"
    end

    test "never splits a multi-byte UTF-8 codepoint (valid strings out)" do
      # 4-byte emoji repeated — a naive byte slice would land mid-codepoint.
      evidence = String.duplicate("🔥", 1_000)
      out = ClaudeAdapter.truncate_evidence(evidence, max_bytes: 101)

      assert byte_size(out) <= 101
      assert String.valid?(out)
    end
  end

  describe "run/3 claw-code hygiene flags (T4.8, UC-009/UC-022)" do
    test "passes the per-dispatch budget ceiling as --max-budget-usd", %{workspace: workspace} do
      assert {:ok, result} =
               ClaudeAdapter.run("do work", workspace, command: @args_stub, max_budget_usd: 0.5)

      args = parse_args(result.output)
      assert pair_present?(args, "--max-budget-usd", "0.5")
    end

    test "passes the minimal tool set as --allowed-tools (least privilege)", %{
      workspace: workspace
    } do
      assert {:ok, result} =
               ClaudeAdapter.run("do work", workspace,
                 command: @args_stub,
                 allowed_tools: ["Read", "Edit", "Bash"]
               )

      args = parse_args(result.output)
      assert "--allowed-tools" in args
      assert "Read" in args
      assert "Edit" in args
      assert "Bash" in args
    end

    test "accepts a comma/space-delimited tool string", %{workspace: workspace} do
      assert {:ok, result} =
               ClaudeAdapter.run("do work", workspace,
                 command: @args_stub,
                 allowed_tools: "Read, Edit Bash"
               )

      args = parse_args(result.output)
      assert "--allowed-tools" in args
      assert "Read" in args
      assert "Edit" in args
      assert "Bash" in args
    end

    test "passes the minimal permission mode as --permission-mode", %{workspace: workspace} do
      assert {:ok, result} =
               ClaudeAdapter.run("do work", workspace,
                 command: @args_stub,
                 permission_mode: "default"
               )

      args = parse_args(result.output)
      assert pair_present?(args, "--permission-mode", "default")
    end

    test "accepts an atom permission mode", %{workspace: workspace} do
      assert {:ok, result} =
               ClaudeAdapter.run("do work", workspace,
                 command: @args_stub,
                 permission_mode: :acceptEdits
               )

      args = parse_args(result.output)
      assert pair_present?(args, "--permission-mode", "acceptEdits")
    end

    test "combines all hygiene flags alongside the base -p/json args", %{workspace: workspace} do
      assert {:ok, result} =
               ClaudeAdapter.run("do work", workspace,
                 command: @args_stub,
                 max_budget_usd: 1.25,
                 allowed_tools: ["Read"],
                 permission_mode: "default"
               )

      args = parse_args(result.output)
      # Base args (T4.1) still present.
      assert "-p" in args
      assert pair_present?(args, "--output-format", "json")
      # Hygiene args (T4.8) appended.
      assert pair_present?(args, "--max-budget-usd", "1.25")
      assert pair_present?(args, "--allowed-tools", "Read")
      assert pair_present?(args, "--permission-mode", "default")
    end

    test "emits no hygiene flags by default (byte-for-byte pre-T4.8 args)", %{
      workspace: workspace
    } do
      assert {:ok, result} = ClaudeAdapter.run("do work", workspace, command: @args_stub)

      args = parse_args(result.output)
      assert args == ["-p", "do work", "--output-format", "json"]
    end

    test "ignores a non-positive budget and empty tool set", %{workspace: workspace} do
      assert {:ok, result} =
               ClaudeAdapter.run("do work", workspace,
                 command: @args_stub,
                 max_budget_usd: 0,
                 allowed_tools: [],
                 permission_mode: ""
               )

      args = parse_args(result.output)
      refute "--max-budget-usd" in args
      refute "--allowed-tools" in args
      refute "--permission-mode" in args
    end
  end

  # Parse the args-echoing stub's stdout ("arg: <value>" per line) back into the
  # argv list the harness received, in order.
  defp parse_args(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "arg: " <> arg -> [arg]
      _ -> []
    end)
  end

  # Assert a flag is immediately followed by the expected value in the argv.
  defp pair_present?(args, flag, value) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [a, b] -> a == flag and b == value end)
  end
end
