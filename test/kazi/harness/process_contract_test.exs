defmodule Kazi.Harness.ProcessContractTest do
  @moduledoc """
  T44.4 (ADR-0055 decision 4b): the controller-owned PROCESS CONTRACT section is a
  stable, versioned, cacheable block rendered from `[conventions]` config ALONE —
  byte-identical across iterations, disabled by `process_contract = false`,
  extendable by verbatim `extra_rules`, and small enough to stay a cacheable head.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Harness.ProcessContract

  describe "section/1" do
    test "the default (process contract on) renders the universal rules" do
      section = ProcessContract.section(Goal.default_conventions())

      assert is_binary(section)
      assert section =~ "Process contract"
      # A representative sample of each universal rule (ADR-0055 decision 4b).
      assert section =~ "conventional commits"
      assert section =~ "Commit as you go"
      assert section =~ "No stubs"
      assert section =~ "docs/lore.md"
      assert section =~ "migration/sequence numbers from origin"
      assert section =~ "exponential-backoff retry"
      assert section =~ "code graph"
    end

    test "process_contract = false disables the section entirely (nil)" do
      assert ProcessContract.section(%{process_contract: false, extra_rules: []}) == nil
    end

    test "is byte-identical across renders regardless of surrounding iteration state" do
      # The section takes ONLY conventions — no iteration/timestamp input — so two
      # renders of the same config are the same bytes (the cacheable-head contract).
      a = ProcessContract.section(Goal.default_conventions())
      b = ProcessContract.section(%{process_contract: true, extra_rules: []})
      assert a == b
    end

    test "extra_rules are appended VERBATIM after the universal rules" do
      section =
        ProcessContract.section(%{
          process_contract: true,
          extra_rules: ["Run mix format before committing.", "Never push to main directly."]
        })

      assert section =~ "- Run mix format before committing."
      assert section =~ "- Never push to main directly."

      # Verbatim AND after the universals: the extra rules trail the last universal.
      universal_at = :binary.match(section, "code graph") |> elem(0)
      extra_at = :binary.match(section, "Run mix format before committing.") |> elem(0)
      assert extra_at > universal_at
    end

    test "the section stays within the ~1 KB cacheable-head budget" do
      # Measured for real, including a couple of extra rules.
      section =
        ProcessContract.section(%{
          process_contract: true,
          extra_rules: ["Run mix format before committing."]
        })

      assert byte_size(section) <= 1024
    end

    test "nil conventions falls back to the default (contract on)" do
      assert ProcessContract.section(nil) == ProcessContract.section(Goal.default_conventions())
    end

    test "a malformed extra_rules entry is dropped, not rendered or crashed" do
      section =
        ProcessContract.section(%{process_contract: true, extra_rules: ["ok", "", 42]})

      assert section =~ "- ok"
      refute section =~ "- 42"
      refute section =~ "- \n"
    end
  end
end
