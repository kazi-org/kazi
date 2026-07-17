defmodule Kazi.Goal.LoaderBrowserAssertionParityTest do
  @moduledoc """
  The loader's `browser` assertion vocabulary and the runner's `ASSERTIONS`
  dispatch table must agree — this pins the parity so they cannot drift again.

  This is a REGRESSION test with a shipped precedent: T49.10 added the `download`
  assertion to `priv/browser/playwright_runner.js` and documented it in
  `kazi schema browser`, but did not add it to the loader's `@browser_assertion_types`.
  The result shipped in a release: every goal using a documented, implemented
  assertion was rejected at LOAD with `unknown type "download"`. The feature was
  unreachable, and no test noticed, because both sides were individually correct —
  only their AGREEMENT was wrong.

  Drift is a real failure in BOTH directions, which is why this asserts set
  equality rather than a subset:

    * runner has it / loader lacks it → rejected at load though it works (T49.10).
    * loader has it / runner lacks it → reaches the runner and comes back a
      permanent `ok: false`, i.e. a `:fail` the author reads as "my UI is broken"
      rather than "that type does not exist" (the L-0018 class the loader guard
      exists to prevent in the first place).

  The runner is the SOURCE OF TRUTH: it is where an assertion is implemented, and
  the loader guard exists only to reject what the runner cannot do.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader

  @runner Path.expand("../../../priv/browser/playwright_runner.js", __DIR__)

  # Reads the keys of the `const ASSERTIONS = { ... }` object literal. Deliberately
  # a plain regex over the source rather than a JS parse: the test must not need a
  # node runtime, and the table's shape (`  <name>: async ({...}) =>`) is fixed by
  # the runner's own documented "to add one, add an entry to ASSERTIONS" contract.
  defp runner_assertion_types do
    body =
      @runner
      |> File.read!()
      |> String.split("const ASSERTIONS = {")
      |> Enum.at(1)

    refute_nil = fn
      nil -> flunk("could not find `const ASSERTIONS = {` in #{@runner}")
      value -> value
    end

    ~r/^  ([a-z0-9_]+): async/m
    |> Regex.scan(refute_nil.(body))
    |> Enum.map(fn [_full, name] -> name end)
  end

  test "the runner's ASSERTIONS table and the loader's vocabulary are the same set" do
    runner = MapSet.new(runner_assertion_types())
    loader = MapSet.new(Loader.browser_assertion_types())

    # Guard against a silently-empty scrape: if the regex ever stops matching, the
    # sets would trivially "agree" at zero and this test would pass vacuously.
    assert MapSet.size(runner) >= 5,
           "scraped only #{MapSet.size(runner)} assertion types from the runner — " <>
             "the ASSERTIONS table shape likely changed and this test is not checking anything"

    implemented_but_unloadable = MapSet.difference(runner, loader)
    loadable_but_unimplemented = MapSet.difference(loader, runner)

    assert MapSet.equal?(runner, loader), """
    The browser assertion vocabulary has drifted.

    Implemented in the runner but REJECTED at load (the T49.10 bug — the type
    works, but every goal using it fails to load):
      #{inspect(MapSet.to_list(implemented_but_unloadable))}

    Admitted by the loader but NOT implemented in the runner (reaches the runner
    and returns a permanent ok: false, read as "my UI is broken"):
      #{inspect(MapSet.to_list(loadable_but_unimplemented))}

    Fix: add the type to @browser_assertion_types in lib/kazi/goal/loader.ex, or
    to the ASSERTIONS table in priv/browser/playwright_runner.js.
    """
  end

  test "download — the T49.10 regression: a documented, implemented type loads" do
    path =
      Path.join(System.tmp_dir!(), "parity_download_#{System.unique_integer([:positive])}.toml")

    File.write!(path, """
    id = "download-regression"
    name = "the export button downloads a CSV"

    [[predicate]]
    id = "dl"
    provider = "browser"
    description = "the export button downloads the CSV"
    url = "https://example.test/export"
    assertions = [
      { type = "download", filename_pattern = "\\\\.csv$" },
    ]
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:ok, _goal} = Loader.load(path)
  end

  test "an unknown type is still rejected, and the error names the valid set" do
    path =
      Path.join(System.tmp_dir!(), "parity_unknown_#{System.unique_integer([:positive])}.toml")

    File.write!(path, """
    id = "unknown-assertion"
    name = "a typo'd assertion type"

    [[predicate]]
    id = "typo"
    provider = "browser"
    description = "a typo'd type"
    url = "https://example.test/"
    assertions = [
      { type = "downlaod", filename_pattern = "\\\\.csv$" },
    ]
    """)

    on_exit(fn -> File.rm(path) end)

    # The guard must still do its job — widening the vocabulary must not weaken it.
    assert {:error, message} = Loader.load(path)
    assert message =~ "unknown type"
    assert message =~ "downlaod"
    assert message =~ "download"
  end
end
