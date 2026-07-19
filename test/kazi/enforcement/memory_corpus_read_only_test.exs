defmodule Kazi.Enforcement.MemoryCorpusReadOnlyTest do
  @moduledoc """
  ADR-0062 decision 5: recall adds no write path to the corpus, and corpus
  files are ELIGIBLE `[enforcement] read_only_paths` (ADR-0042) so a goal can
  lease its corpus read-only during a run — the inner agent cannot edit the
  project's beliefs to make recall agree with its work.

  This pins that the default corpus (`Kazi.Memory.SemanticIndex.default_corpus/0`)
  is a VALID `read_only_paths` list: an `Kazi.Enforcement` profile built from it
  is active and reports the `:read_only_lease` guarantee, the same machinery
  `Kazi.Enforcement.Isolation` already enforces for any other declared path.
  """
  use ExUnit.Case, async: true

  alias Kazi.Enforcement
  alias Kazi.Memory.SemanticIndex

  test "an enforcement profile covering the default corpus is valid and active" do
    profile = Enforcement.new(enabled: true, read_only_paths: SemanticIndex.default_corpus())

    assert Enforcement.active?(profile)
    assert :read_only_lease in Enforcement.guarantee_atoms(profile)
  end

  test "the default corpus globs are non-empty repo-relative path patterns" do
    corpus = SemanticIndex.default_corpus()

    refute Enum.empty?(corpus)
    assert Enum.all?(corpus, &is_binary/1)
    refute Enum.any?(corpus, &String.starts_with?(&1, "/"))
  end
end
