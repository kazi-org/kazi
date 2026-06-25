defmodule Kazi.Providers.StaticExamplesTest do
  @moduledoc """
  T32.7 (ADR-0043) acceptance: the shipped `static` recipes under priv/examples/
  PARSE (load through the real loader, including the static key validation) and
  EVALUATE — the declared gate produces the right status against a representative
  analyzer output.

  The example `cmd`s name real tools that may not be installed here (mix dialyzer,
  semgrep), so each test loads the example's declared config, swaps only the
  `cmd`/`args` for a fixture that emits the findings, and asserts the verdict —
  proving the DECLARATION the recipe ships is correct.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Predicate
  alias Kazi.Providers.Static

  @examples Path.join([File.cwd!(), "priv", "examples"])

  setup do
    dir =
      Path.join(System.tmp_dir!(), "kazi_static_examples_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp example_config(name) do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :static, config: config}]}} =
             Loader.load(Path.join(@examples, name))

    config
  end

  defp evaluate_with(config, out, code, ws) do
    file = Path.join(ws, "out-#{System.unique_integer([:positive])}.txt")
    File.write!(file, out)
    config = Map.merge(config, %{cmd: "sh", args: ["-c", "cat '#{file}'; exit #{code}"]})
    Static.evaluate(Predicate.new(:analysis, :static, config: config), %{workspace: ws})
  end

  test "static_dialyzer.toml: clean passes, a warning fails with evidence", %{workspace: ws} do
    config = example_config("static_dialyzer.toml")
    assert config.format == "dialyzer"

    assert evaluate_with(config, "", 0, ws).status == :pass

    fail =
      evaluate_with(config, "lib/a.ex:9:no_return Function f/0 has no local return.\n", 2, ws)

    assert fail.status == :fail
    assert [%{file: "lib/a.ex", line: 9}] = fail.diagnostics
  end

  test "static_sarif.toml: ratchets on its stored baseline, fails on a new finding",
       %{workspace: ws} do
    config = example_config("static_sarif.toml")
    assert config.format == "sarif"
    assert config.baseline == "stored"

    clean = ~s({"runs":[{"results":[]}]})

    one =
      ~s({"runs":[{"results":[{"ruleId":"r","level":"error",) <>
        ~s("message":{"text":"m"},"locations":[{"physicalLocation":) <>
        ~s({"artifactLocation":{"uri":"a.ts"},"region":{"startLine":3}}}]}]}]})

    # First run (clean) seeds the baseline at 0.
    assert evaluate_with(config, clean, 0, ws).status == :pass
    # A later run with a NEW finding (exit 0, SARIF-style) fails on the parsed count.
    assert evaluate_with(config, one, 0, ws).status == :fail
  end
end
