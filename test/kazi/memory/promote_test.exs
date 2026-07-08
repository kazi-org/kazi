defmodule Kazi.Memory.PromoteTest do
  @moduledoc """
  ADR-0063 decision 3: `Kazi.Memory.Promote` writes an approved proposal into
  its routed corpus file as an ordinary working-tree edit, carrying a
  `kx:<fingerprint>` provenance trailer, and is idempotent (re-promoting a
  proposal whose marker is already present is a no-op).
  """
  use ExUnit.Case, async: true

  alias Kazi.Memory.Promote
  alias Kazi.ReadModel.ProposedMemory

  @moduletag :tmp_dir

  defp proposal(overrides \\ %{}) do
    struct(
      ProposedMemory,
      Map.merge(
        %{
          proposal_ref: "mem-abc123def456",
          fingerprint: "abc123def456",
          class: "landmine",
          content: "predicate a repeated 3 times without change",
          goal_ref: "some-goal",
          target_doc: "docs/lore.md"
        },
        overrides
      )
    )
  end

  describe "target_doc/1 -- the ADR-0036 tier map" do
    test "invariant/landmine route to the lore file" do
      assert Promote.target_doc("invariant") == "docs/lore.md"
      assert Promote.target_doc("landmine") == "docs/lore.md"
    end

    test "finding/benchmark route to the devlog" do
      assert Promote.target_doc("finding") == "docs/devlog.md"
      assert Promote.target_doc("benchmark") == "docs/devlog.md"
    end

    test "decision routes to the ADR directory" do
      assert Promote.target_doc("decision") == "docs/adr"
    end
  end

  test "promote/2 appends the entry with a kx: provenance trailer", %{tmp_dir: tmp_dir} do
    assert {:ok, path} = Promote.promote(proposal(), tmp_dir)

    content = File.read!(path)
    assert content =~ "kx:abc123def456"
    assert content =~ "predicate a repeated 3 times without change"
    assert path == Path.join(tmp_dir, "docs/lore.md")
  end

  test "promote/2 is idempotent -- the same fingerprint is never appended twice", %{
    tmp_dir: tmp_dir
  } do
    entry = proposal()

    {:ok, path} = Promote.promote(entry, tmp_dir)
    first_content = File.read!(path)

    {:ok, ^path} = Promote.promote(entry, tmp_dir)
    second_content = File.read!(path)

    assert first_content == second_content
  end

  test "promote/2 creates the target file when it does not yet exist", %{tmp_dir: tmp_dir} do
    refute File.exists?(Path.join(tmp_dir, "docs/lore.md"))
    assert {:ok, _path} = Promote.promote(proposal(), tmp_dir)
    assert File.exists?(Path.join(tmp_dir, "docs/lore.md"))
  end

  test "promote/2 writes a decision as a drafted ADR stub carrying its own kx: trailer", %{
    tmp_dir: tmp_dir
  } do
    decision =
      proposal(%{
        class: "decision",
        target_doc: "docs/adr",
        fingerprint: "decision-fp-1"
      })

    assert {:ok, path} = Promote.promote(decision, tmp_dir)
    assert content = File.read!(path)
    assert content =~ "kx:decision-fp-1"
    assert String.starts_with?(Path.basename(path), "0001-")
  end
end
