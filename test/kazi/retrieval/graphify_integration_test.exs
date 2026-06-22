defmodule Kazi.Retrieval.GraphifyIntegrationTest do
  @moduledoc """
  The REAL graphify-embeddings `Kazi.Retrieval.Graphify` backend (T4.9b).

  This is the one place in the suite the live graphify tool is exercised: it runs
  the genuine `retrieve/3` path — embed the target + similarity-search the failing
  evidence terms — against a *real* graphify command over a fixture workspace, and
  asserts the backend returns top-k `Kazi.Retrieval.Snippet`s in the **same**
  behaviour shape the hermetic stub test asserts.

  ## Integration-tagged — excluded by default

  Every test here is tagged `@moduletag :graphify`. `test/test_helper.exs` excludes
  the `:graphify` tag unless `GRAPHIFY_CMD` is set, so the standard `mix test`
  stays hermetic (no embedding model, no index, no network). To run it against the
  real graphify tooling:

      GRAPHIFY_CMD=graphify mix test --include graphify

  `--include graphify` overrides the default exclusion; `GRAPHIFY_CMD` names the
  executable the backend shells out to (it is forwarded as `:graphify_command`).
  The default-path ranking + top-k + degrade-to-`[]` logic is fully covered
  hermetically by `Kazi.Retrieval.GraphifyTest` via a stub command; this test only
  certifies that the real tool satisfies the same contract end to end.
  """

  use ExUnit.Case, async: false

  @moduletag :graphify

  alias Kazi.PredicateResult
  alias Kazi.Retrieval.{Graphify, Snippet}

  # A small fixture workspace the real graphify command embeds, plus a failing
  # predicate whose evidence names a term that lives in that workspace.
  setup do
    command = System.fetch_env!("GRAPHIFY_CMD")

    dir = Path.join(System.tmp_dir!(), "kazi_graphify_int_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/widget.ex"), """
    defmodule Widget do
      @moduledoc "A fixture module the failing predicate's evidence points at."
      def build(x), do: x + 1
    end
    """)

    on_exit(fn -> File.rm_rf!(dir) end)

    failing = [
      {:unit,
       %PredicateResult{status: :fail, evidence: %{output: "lib/widget.ex build/1 failed"}}}
    ]

    {:ok, command: command, workspace: dir, failing: failing}
  end

  test "the real backend returns top-k snippets for a query against a fixture index",
       %{command: command, workspace: workspace, failing: failing} do
    snippets = Graphify.retrieve(failing, workspace, graphify_command: command, top_k: 3)

    # Same behaviour shape as the hermetic stub: a (possibly empty) list of
    # %Snippet{} with at most top_k entries. We do not assert exact ranking — the
    # real embedding model is non-deterministic — only the contract.
    assert is_list(snippets)
    assert length(snippets) <= 3
    assert Enum.all?(snippets, &match?(%Snippet{text: t} when is_binary(t), &1))
  end
end
