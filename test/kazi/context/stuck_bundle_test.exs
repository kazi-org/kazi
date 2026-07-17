defmodule Kazi.Context.StuckBundleTest do
  use ExUnit.Case, async: true

  alias Kazi.Context.StuckBundle
  alias Kazi.ContextStore.Snippet

  doctest Kazi.Context.StuckBundle

  describe "assemble/2" do
    test "carries failing predicates, changed files, and snippets" do
      bundle =
        StuckBundle.assemble(%{
          failing: [{:code, %{output: "expected 200 got 404"}}],
          changed_files: ["lib/router.ex"],
          snippets: [Snippet.new("prior 404 in handler", source: "kazi:run:g:iter:2:test-log")]
        })

      assert bundle["failing_predicates"] == [
               %{"id" => "code", "failure" => "expected 200 got 404"}
             ]

      assert bundle["changed_files"] == ["lib/router.ex"]

      assert [%{"source" => "kazi:run:g:iter:2:test-log", "text" => "prior 404 in handler"}] =
               bundle["snippets"]

      assert is_integer(bundle["bytes"])
    end

    test "omits snippets when no store provided them" do
      bundle = StuckBundle.assemble(%{failing: [{:code, %{output: "boom"}}], changed_files: []})
      assert bundle["snippets"] == []
    end

    test "redacts secrets in the failure text" do
      bundle =
        StuckBundle.assemble(%{
          failing: [{:db, %{output: "connect postgres://app:AKIAIOSFODNN7EXAMPLE@h/db failed"}}]
        })

      [%{"failure" => failure}] = bundle["failing_predicates"]
      refute failure =~ "AKIAIOSFODNN7EXAMPLE"
      assert failure =~ "[REDACTED]"
    end

    test "non-map evidence is still summarized" do
      bundle = StuckBundle.assemble(%{failing: [{:code, {:cmd_unrunnable, "no binary"}}]})
      assert [%{"id" => "code", "failure" => failure}] = bundle["failing_predicates"]
      assert failure =~ "cmd_unrunnable"
    end
  end

  describe "budget bound" do
    test "the rendered bundle never exceeds the byte budget (snippets dropped first)" do
      big_snippets =
        for i <- 1..20, do: Snippet.new(String.duplicate("x", 500), source: "s#{i}")

      bundle =
        StuckBundle.assemble(
          %{
            failing: [{:code, %{output: "short failure"}}],
            changed_files: ["lib/a.ex"],
            snippets: big_snippets
          },
          budget: 600
        )

      assert byte_size(StuckBundle.render(bundle)) <= 600
      assert bundle["bytes"] <= 600
      # the irreducible failing signal survives even when snippets are dropped.
      assert bundle["failing_predicates"] == [%{"id" => "code", "failure" => "short failure"}]
    end

    test "a single oversized failure is hard-capped to the budget" do
      bundle =
        StuckBundle.assemble(
          %{failing: [{:code, %{output: String.duplicate("y", 5_000)}}]},
          budget: 300
        )

      assert byte_size(StuckBundle.render(bundle)) <= 300
    end

    # issue #1075: the LAST failing predicate's failure text is the real error the
    # higher rung needs. A prior fit pass blanked it to `""` when the (expendable)
    # changed-files list alone filled the budget — hiding the git cause behind an
    # empty `"failure"`. The failure must survive NON-EMPTY; the file list yields.
    test "the last predicate's failure is never blanked to make room for changed files" do
      git_cause = "fatal: no upstream configured for branch 'kazi-partition/p-x-ab12'"
      changed = for i <- 1..40, do: "lib/module_number_#{i}.ex"

      bundle =
        StuckBundle.assemble(
          %{failing: [{:landed, %{output: git_cause}}], changed_files: changed},
          budget: 400
        )

      [%{"id" => "landed", "failure" => failure}] = bundle["failing_predicates"]
      refute failure == "", "the real git cause must not be blanked to an empty string"
      assert failure =~ "no upstream configured", "the actual error must be visible"
      # The bundle still respects its byte budget — the file list was shed, not
      # the failure.
      assert byte_size(StuckBundle.render(bundle)) <= 400
      assert bundle["bytes"] <= 400
    end

    test "a huge failure with a huge file list keeps a non-empty failure within budget" do
      bundle =
        StuckBundle.assemble(
          %{
            failing: [{:landed, %{output: String.duplicate("boom ", 400)}}],
            changed_files: for(i <- 1..50, do: "lib/really_long_module_path_number_#{i}.ex")
          },
          budget: 500
        )

      [%{"failure" => failure}] = bundle["failing_predicates"]
      refute failure == ""
      assert byte_size(StuckBundle.render(bundle)) <= 500
    end
  end

  describe "render/1" do
    test "produces a compact text block with the section headers" do
      text =
        %{
          failing: [{:code, %{output: "boom"}}],
          changed_files: ["lib/a.ex"]
        }
        |> StuckBundle.assemble()
        |> StuckBundle.render()

      assert text =~ "## Failing predicates"
      assert text =~ "- code: boom"
      assert text =~ "## Last changed files"
      assert text =~ "- lib/a.ex"
    end
  end
end
