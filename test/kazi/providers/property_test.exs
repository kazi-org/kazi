defmodule Kazi.Providers.PropertyTest do
  # Tier 2: real boundary. These run a command that emits RECORDED PropEr console
  # output (the summary PropCheck surfaces under `mix test`) and assert the
  # resulting PredicateResult, proving the :property provider reads cases-passed/N
  # and the shrunk counterexample from the PARSED output, not the exit code alone
  # (T32.8, ADR-0043). No live PropCheck run is needed.
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Property

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_property_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # A command that prints recorded `output` and exits `code`, so the parser sees
  # real PropEr text.
  defp emit(ws, output, code) do
    fixture = Path.join(ws, "out-#{System.unique_integer([:positive])}.txt")
    File.write!(fixture, output)
    %{cmd: "sh", args: ["-c", "cat '#{fixture}'; exit #{code}"]}
  end

  defp evaluate(config, ws),
    do: Property.evaluate(Predicate.new(:prop, :property, config: config), %{workspace: ws})

  @passed """
  ....................................................................................................
  OK: Passed 100 test(s).
  """

  @failed_shrunk """
  ..!
  Failed: After 3 test(s).
  [7,13,2]
  Shrinking ....(4 time(s))
  [0]
  """

  @failed_counterexample """
  1) property list reverse is involutive (MyTest)
     test/my_test.exs:12
     Property Elixir.MyTest.reverse_involutive() failed. Counter-Example is:
     [0, 1]

     stacktrace:
       test/my_test.exs:12
  Failed: After 5 test(s).
  """

  test "implements the PredicateProvider behaviour" do
    behaviours = Property.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  describe "passing property" do
    test "all cases pass -> :pass with score 1.0", %{workspace: ws} do
      result = evaluate(Map.merge(emit(ws, @passed, 0), %{num_tests: 100}), ws)
      assert %PredicateResult{status: :pass} = result
      assert result.score == 1.0
      assert result.direction == :higher_better
      assert result.evidence.cases_passed == 100
    end
  end

  describe "failing property surfaces the shrunk counterexample + score" do
    test "Failed: After N with a Shrinking counterexample", %{workspace: ws} do
      result = evaluate(Map.merge(emit(ws, @failed_shrunk, 1), %{num_tests: 100}), ws)
      assert result.status == :fail
      # Failed after the 3rd test => 2 cases passed first; score = 2/100.
      assert result.evidence.cases_passed == 2
      assert result.score == 0.02
      assert result.direction == :higher_better
      # The SHRUNK input is the evidence, not the original [7,13,2].
      assert result.evidence.counterexample == "[0]"
    end

    test "PropCheck's 'Counter-Example is:' format is also parsed", %{workspace: ws} do
      result = evaluate(Map.merge(emit(ws, @failed_counterexample, 1), %{num_tests: 100}), ws)
      assert result.status == :fail
      assert result.evidence.cases_passed == 4
      assert result.evidence.counterexample == "[0, 1]"
    end

    test "a higher cases_passed scores higher (the gradient)", %{workspace: ws} do
      early =
        evaluate(Map.merge(emit(ws, "Failed: After 2 test(s).\n", 1), %{num_tests: 100}), ws)

      late =
        evaluate(Map.merge(emit(ws, "Failed: After 50 test(s).\n", 1), %{num_tests: 100}), ws)

      assert late.score > early.score
    end
  end

  describe "error vs fail boundary" do
    test "a non-zero exit with NO property failure is :error, not :fail", %{workspace: ws} do
      # A compile error / crashed suite: mix test exits 1 but printed no PropEr
      # failure summary. That is infra, not failing property work.
      result = evaluate(emit(ws, "** (CompileError) bad\n", 1), ws)
      assert result.status == :error
    end

    test "a missing binary is :error", %{workspace: ws} do
      result = evaluate(%{cmd: "definitely-not-a-real-binary-xyz", args: []}, ws)
      assert result.status == :error
    end
  end

  test "an unsupported kind is an :error" do
    result = Property.evaluate(%Predicate{id: :x, kind: :tests, config: %{}}, %{})
    assert result.status == :error
  end
end
