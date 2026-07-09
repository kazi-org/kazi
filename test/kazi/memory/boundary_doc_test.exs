defmodule Kazi.Memory.BoundaryDocTest do
  @moduledoc """
  Issue #975: pins that `docs/memory.md` states the boundary between kazi
  memory (ADR-0062/0063), Claude Code's own native per-project memory, and the
  `docs/lore.md`/`docs/devlog.md` wiki convention -- and that `docs/lore.md`
  and `docs/devlog.md` point back at it. A doc-content pin, not a functional
  test: it greps the committed docs for the stable heading/cross-link strings
  rather than asserting behavior.
  """
  use ExUnit.Case, async: true

  @boundary_heading "## Boundary: kazi memory vs. Claude Code memory vs. docs/lore.md / docs/devlog.md"

  test "docs/memory.md has the boundary section" do
    content = File.read!(Path.join(["docs", "memory.md"]))

    assert content =~ @boundary_heading
    assert content =~ "Claude Code's own native per-project memory is a THIRD"
  end

  test "docs/lore.md and docs/devlog.md cross-link to the boundary section" do
    lore = File.read!(Path.join(["docs", "lore.md"]))
    devlog = File.read!(Path.join(["docs", "devlog.md"]))

    assert lore =~ "docs/memory.md"
    assert devlog =~ "docs/memory.md"
  end
end
