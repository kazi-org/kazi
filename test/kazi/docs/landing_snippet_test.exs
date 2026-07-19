defmodule Kazi.Docs.LandingSnippetTest do
  @moduledoc """
  T44.13 (ADR-0055): the copy-pasteable Tier-0 `landed` predicate snippet in
  docs/landing.md must ACTUALLY LOAD. This test extracts the exact `toml` fence
  from the doc and round-trips it through the real goal-file loader, so a snippet
  that ever stops parsing (a bad edit) fails CI — the doc's promise is enforced,
  not eyeballed.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader

  @doc_path Path.join([File.cwd!(), "docs", "landing.md"])

  test "the Tier-0 landed snippet round-trips through the real loader" do
    toml = extract_tier0_snippet(File.read!(@doc_path))

    assert {:ok, data} = Toml.decode(toml)
    assert {:ok, %Goal{predicates: predicates}} = Loader.from_map(data)

    landed = Enum.find(predicates, &(to_string(&1.id) == "landed"))
    assert landed, "the snippet must declare a `landed` predicate"
    assert landed.kind == :custom_script
    # It is a real, runnable custom_script predicate (cmd + verdict), not a stub.
    assert landed.config[:cmd] == "sh"
    assert landed.config[:verdict] == "exit_zero"
  end

  # Pull the exact ```toml fenced block that carries the Tier-0 example.
  defp extract_tier0_snippet(markdown) do
    markdown
    |> String.split("```toml")
    |> Enum.find(&String.contains?(&1, "tier0-landing-example"))
    |> case do
      nil -> flunk("no ```toml block containing the Tier-0 example found in docs/landing.md")
      chunk -> chunk |> String.split("```", parts: 2) |> hd()
    end
  end
end
