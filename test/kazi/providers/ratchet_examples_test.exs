defmodule Kazi.Providers.RatchetExamplesTest do
  @moduledoc """
  T32.3 (ADR-0041) acceptance: the two shipped `ratchet` recipes under
  priv/examples/ both PARSE (through the real loader, including the ratchet key
  validation) and EVALUATE — proving the SAME mode services a coverage AND a size
  example, differing only in config.

  Like the custom_script examples test, each recipe's `cmd` names a real tool that
  may not be installed here, so we load the declared metric/baseline/direction and
  swap only the metric command for a fixture that emits the signal, then assert the
  verdict — proving the DECLARATION the recipe ships is correct.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Predicate
  alias Kazi.Providers.Ratchet
  alias Kazi.Ratchet.Store

  @examples Path.join([File.cwd!(), "priv", "examples"])

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_ratchet_ex_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # Load the single ratchet predicate config from an example file.
  defp example_config(name) do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :ratchet, id: id, config: config}]}} =
             Loader.load(Path.join(@examples, name))

    {id, config}
  end

  # A metric command that prints `n` to stdout.
  defp const(n), do: %{"cmd" => "sh", "args" => ["-c", "printf '%s' '#{n}'"]}

  defp evaluate(id, config, ws) do
    Ratchet.evaluate(Predicate.new(id, :ratchet, config: config), %{workspace: ws})
  end

  test "ratchet_coverage.toml: higher_better, stored baseline — seeds then ratchets up", %{
    workspace: ws
  } do
    {id, config} = example_config("ratchet_coverage.toml")
    assert config.direction == "higher_better"
    assert config.baseline == "stored"

    # Swap only the metric command (the recipe names a coverage tool we may not
    # have); the declared direction/baseline drive the verdict.
    seed = evaluate(id, %{config | metric: const("82")}, ws)
    assert seed.status == :pass
    assert seed.score == 82.0
    assert seed.evidence.baseline_source == :seed
    assert Store.read(Path.join(ws, ".kazi"), id) == {:ok, 82.0}

    improved = evaluate(id, %{config | metric: const("90")}, ws)
    assert improved.status == :pass
    assert improved.evidence.stored == true
    assert Store.read(Path.join(ws, ".kazi"), id) == {:ok, 90.0}

    regressed = evaluate(id, %{config | metric: const("70")}, ws)
    assert regressed.status == :fail
    assert Store.read(Path.join(ws, ".kazi"), id) == {:ok, 90.0}
  end

  test "ratchet_size.toml: lower_better, the SAME mode gates size", %{workspace: ws} do
    {id, config} = example_config("ratchet_size.toml")
    assert config.direction == "lower_better"
    assert config.baseline == "main"
    assert config.allowed_regression == 1024

    # The recipe's baseline is a git ref; pin a literal baseline to exercise the
    # declared metric + direction deterministically (the git-ref resolution itself
    # is covered in Kazi.RatchetTest).
    config = %{config | baseline: 5000}

    under = evaluate(id, %{config | metric: const("4096")}, ws)
    assert under.status == :pass
    assert under.score == 4096.0
    assert under.direction == :lower_better

    # Within the 1 KiB regression budget the recipe declares.
    within = evaluate(id, %{config | metric: const("5500")}, ws)
    assert within.status == :pass

    over = evaluate(id, %{config | metric: const("8000")}, ws)
    assert over.status == :fail
    assert over.evidence.regression == 3000.0
  end
end
