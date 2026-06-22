defmodule Kazi.Retrieval.GraphifyTest do
  # Tier-2: exercises the graphify backend's System.cmd boundary via an injected
  # stub executable (a shell script emitting fixture similarity matches), so the
  # ranking + top-k logic is covered WITHOUT the real graphify tooling, an
  # embedding model, an index, or the network. Hermetic — the "binary" is a script
  # we write to a temp dir. The real tool is exercised only by the
  # `:graphify`-tagged integration test (excluded by default).
  use ExUnit.Case, async: true

  alias Kazi.PredicateResult
  alias Kazi.Retrieval.{Graphify, Snippet}

  # A failing slice in the {id, %PredicateResult{}} shape `retrieve/3` receives.
  defp failing(evidence \\ %{output: "lib/widget.ex:42 boom"}) do
    [{:unit, %PredicateResult{status: :fail, evidence: evidence}}]
  end

  # Write an executable shell-script "graphify" into a temp dir and return its
  # path, so the backend's System.cmd boundary is exercised for real.
  defp write_stub!(body) do
    dir = Path.join(System.tmp_dir!(), "kazi_graphify_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "graphify_stub.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end

  defp emit_json(json), do: write_stub!("cat <<'EOF'\n#{json}\nEOF\n")

  test "returns top-k snippets ranked by descending similarity score" do
    json =
      ~s({"matches":[) <>
        ~s({"text":"low","source":"lib/c.ex","score":0.10},) <>
        ~s({"text":"high","source":"lib/a.ex","score":0.95},) <>
        ~s({"text":"mid","source":"lib/b.ex","score":0.50}) <>
        ~s(]})

    stub = emit_json(json)

    assert [
             %Snippet{text: "high", source: "lib/a.ex"},
             %Snippet{text: "mid", source: "lib/b.ex"}
           ] = Graphify.retrieve(failing(), ".", graphify_command: stub, top_k: 2)
  end

  test "defaults to top 5 when :top_k is not given" do
    matches =
      0..9
      |> Enum.map(fn i -> ~s({"text":"t#{i}","score":#{10 - i}}) end)
      |> Enum.join(",")

    stub = emit_json(~s({"matches":[#{matches}]}))

    snippets = Graphify.retrieve(failing(), ".", graphify_command: stub)
    assert length(snippets) == 5
    assert Enum.map(snippets, & &1.text) == ["t0", "t1", "t2", "t3", "t4"]
  end

  test "a match with no source yields a snippet with a nil source" do
    stub = emit_json(~s({"matches":[{"text":"orphan","score":0.7}]}))

    assert [%Snippet{text: "orphan", source: nil}] =
             Graphify.retrieve(failing(), ".", graphify_command: stub)
  end

  test "equal scores keep a stable, total order (deterministic across runs)" do
    json =
      ~s({"matches":[) <>
        ~s({"text":"b","source":"lib/z.ex","score":0.5},) <>
        ~s({"text":"a","source":"lib/z.ex","score":0.5},) <>
        ~s({"text":"a","source":"lib/a.ex","score":0.5}) <>
        ~s(]})

    stub = emit_json(json)

    # Tiebreak is {-score, source, text}: same score -> by source, then text.
    # lib/a.ex "a" sorts first; then lib/z.ex "a" before lib/z.ex "b".
    assert ["lib/a.ex", "lib/z.ex", "lib/z.ex"] =
             Graphify.retrieve(failing(), ".", graphify_command: stub)
             |> Enum.map(& &1.source)

    assert ["a", "a", "b"] =
             Graphify.retrieve(failing(), ".", graphify_command: stub)
             |> Enum.map(& &1.text)
  end

  test "the failing evidence terms are passed to the command as the query" do
    # Echo the args back as a single match's text so we can assert the query the
    # backend built from the failing evidence.
    stub =
      write_stub!(~s(printf '{"matches":[{"text":"%s","score":1}]}' "$*"\n))

    [%Snippet{text: text}] =
      Graphify.retrieve(
        [{:unit, %PredicateResult{status: :fail, evidence: %{output: "lib/widget.ex:42"}}}],
        ".",
        graphify_command: stub
      )

    assert text =~ "similarity-search --format json --query"
    # Tokens pulled from the evidence (path + the id) appear in the query.
    assert text =~ "lib/widget.ex"
    assert text =~ "unit"
  end

  test "an empty matches array yields no snippets" do
    stub = emit_json(~s({"matches":[]}))
    assert [] = Graphify.retrieve(failing(), ".", graphify_command: stub)
  end

  # --- Retrieval augments; a failure degrades to [], never a crash --------------

  test "a non-zero exit degrades to [] (retrieval never fails the loop)" do
    stub = write_stub!("echo boom >&2\nexit 1\n")
    assert [] = Graphify.retrieve(failing(), ".", graphify_command: stub)
  end

  test "malformed JSON degrades to []" do
    stub = emit_json("not json at all")
    assert [] = Graphify.retrieve(failing(), ".", graphify_command: stub)
  end

  test "JSON without a matches list degrades to []" do
    stub = emit_json(~s({"unexpected":true}))
    assert [] = Graphify.retrieve(failing(), ".", graphify_command: stub)
  end

  test "a missing command degrades to [] rather than raising" do
    assert [] =
             Graphify.retrieve(failing(), ".",
               graphify_command: "definitely_no_such_graphify_binary_xyz"
             )
  end

  test "malformed individual matches are dropped, valid ones kept" do
    json =
      ~s({"matches":[) <>
        ~s({"no_text":true},) <>
        ~s({"text":"keep","score":0.9},) <>
        ~s(42) <>
        ~s(]})

    stub = emit_json(json)
    assert [%Snippet{text: "keep"}] = Graphify.retrieve(failing(), ".", graphify_command: stub)
  end

  test "implements the Kazi.Retrieval behaviour" do
    behaviours =
      Graphify.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Kazi.Retrieval in behaviours
  end
end
