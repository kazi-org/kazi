defmodule Kazi.Goal.RoadmapRenderTest do
  @moduledoc """
  T45.5 (UC-059, ADR-0075): the PURE renderer behind `kazi plan render`. A roadmap
  plus a `goal-id => verdict` map renders to deterministic markdown — a
  wave-sectioned WBS whose waves are the `needs`-DAG frontiers, whose checkboxes
  are the verdicts (`[x]` only for `:converged`), with progress counts and a loud
  GENERATED banner. No I/O, no read-model — the CLI supplies the verdict map.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Roadmap
  alias Kazi.Goal.Roadmap.Render

  # A minimal inline goal-file map (the loader requires ≥1 predicate). `name`
  # gives the rendered item a human title.
  defp goal_map(id, name) do
    %{
      "id" => id,
      "name" => name,
      "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
    }
  end

  defp entry(id, needs \\ []) do
    e = %{"id" => id, "goal" => goal_map("#{id}-goal", "the #{id} goal")}
    if needs == [], do: e, else: Map.put(e, "needs", needs)
  end

  # A -> {B, C} -> D diamond as a loaded roadmap.
  defp diamond do
    {:ok, roadmap} =
      Roadmap.from_map(%{
        "goals" => [entry("a"), entry("b", ["a"]), entry("c", ["a"]), entry("d", ["b", "c"])]
      })

    roadmap
  end

  # The ordered list of `id` tokens as they appear across the rendered WBS items.
  defp rendered_item_ids(markdown) do
    Regex.scan(~r/^- \[[ x]\] `([a-z]+)`/m, markdown)
    |> Enum.map(fn [_full, id] -> id end)
  end

  # The single WBS item line for one goal id.
  defp item_line(markdown, id) do
    markdown
    |> String.split("\n")
    |> Enum.find(fn line -> Regex.match?(~r/^- \[[ x]\] `#{id}`/, line) end)
  end

  defp progress_line(markdown) do
    markdown |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "**Progress:**"))
  end

  describe "render/2 — structure + banner" do
    test "emits a prominent GENERATED — DO NOT HAND-EDIT banner" do
      md = Render.render(diamond(), %{})

      assert md =~ Render.banner_headline()
      assert md =~ "DO NOT HAND-EDIT"
      # The banner is at the very top — before any wave section.
      assert String.split(md, "## Wave 1") |> hd() =~ Render.banner_headline()
    end

    test "waves match the roadmap's `needs`-DAG frontiers (the same as --explain)" do
      roadmap = diamond()
      md = Render.render(roadmap, %{})

      # The frontier layering the executor/`--explain` compute.
      assert Roadmap.frontiers(roadmap) == [["a"], ["b", "c"], ["d"]]

      # Section headings, in order, one per wave.
      wave_headings = Regex.scan(~r/^## Wave (\d+)$/m, md) |> Enum.map(fn [_, n] -> n end)
      assert wave_headings == ["1", "2", "3"]

      # Wave 2 holds exactly {b, c}; d is not in it.
      wave2 = md |> String.split("## Wave 2") |> Enum.at(1) |> String.split("## Wave 3") |> hd()
      assert wave2 =~ "`b`"
      assert wave2 =~ "`c`"
      refute wave2 =~ "`d`"

      # The item order across the whole doc is the flattened frontier order.
      assert rendered_item_ids(md) == List.flatten(Roadmap.frontiers(roadmap))
    end
  end

  describe "render/2 — checkbox state from verdicts" do
    test "a converged goal renders [x]; everything else renders [ ]" do
      md =
        Render.render(diamond(), %{
          "a" => :converged,
          "b" => :pending,
          "c" => :unknown,
          "d" => :pending
        })

      assert md =~ "- [x] `a`"
      assert md =~ "- [ ] `b`"
      assert md =~ "- [ ] `c`"
      assert md =~ "converged"
      assert md =~ "pending"
      assert md =~ "unknown"
    end

    test "a goal absent from the verdict map is unknown, not converged" do
      md = Render.render(diamond(), %{})
      assert md =~ "- [ ] `a`"
      refute md =~ "- [x] `a`"
    end

    test "progress counts the converged goals" do
      md = Render.render(diamond(), %{"a" => :converged, "b" => :converged})
      assert md =~ "**Progress:** 2 / 4 goals converged (50%)"
    end
  end

  describe "render/2 — determinism + incremental re-render" do
    test "the same roadmap + verdicts renders byte-identical markdown" do
      roadmap = diamond()
      verdicts = %{"a" => :converged, "b" => :pending, "c" => :pending, "d" => :pending}

      assert Render.render(roadmap, verdicts) == Render.render(roadmap, verdicts)
    end

    test "flipping ONE verdict updates only that goal's line (and the count)" do
      roadmap = diamond()
      before = Render.render(roadmap, %{"a" => :converged, "b" => :pending})
      after_ = Render.render(roadmap, %{"a" => :converged, "b" => :converged})

      # Only b's WBS line and the progress-count line differ; a/c/d lines are
      # byte-stable — the re-render is an incremental projection of live state.
      assert item_line(before, "b") != item_line(after_, "b")
      assert item_line(after_, "b") =~ "- [x] `b`"
      assert progress_line(before) != progress_line(after_)

      for id <- ~w(a c d) do
        assert item_line(before, id) == item_line(after_, id),
               "goal #{id}'s line changed when only b's verdict flipped"
      end
    end
  end
end
