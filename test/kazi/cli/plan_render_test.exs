defmodule Kazi.CLI.PlanRenderTest do
  @moduledoc """
  T45.5 (UC-059, ADR-0075): `kazi plan render <roadmap>` end-to-end through the
  real CLI exec core. Pins:

    1. the argv boundary parses `plan render <roadmap>` (and rejects a missing arg)
       as a SUBCOMMAND of `plan` — never a prose idea;
    2. rendering a seeded roadmap emits deterministic markdown with the banner and
       per-goal checkboxes matching the read-model verdicts (a converged goal → `[x]`);
    3. the rendered waves match `apply <roadmap> --explain`'s frontiers;
    4. a re-render after a verdict changes reflects the new state;
    5. `--out <path>` writes the same markdown to a file (stdout stays clean);
    6. a broken/unloadable roadmap is a non-zero error, not a crash.

  Hermetic: the test SQLite Sandbox read-model, `ReadModel.record_iteration` to
  seed verdicts, no harness, no network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{CLI, PredicateResult, PredicateVector, ReadModel, Repo}

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  # --- argv boundary ---------------------------------------------------------

  describe "parse/1" do
    test "`plan render <roadmap>` parses to the plan_render command" do
      assert {:plan_render, "r.roadmap.toml", opts} =
               CLI.parse(["plan", "render", "r.roadmap.toml"])

      assert opts[:out] == nil
    end

    test "`plan render <roadmap> --out <path>` carries the file target" do
      assert {:plan_render, "r.roadmap.toml", opts} =
               CLI.parse(["plan", "render", "r.roadmap.toml", "--out", "PLAN.md"])

      assert opts[:out] == "PLAN.md"
    end

    test "`plan render` with no roadmap is a usage error" do
      assert {:error, message} = CLI.parse(["plan", "render"])
      assert message =~ "roadmap-file"
    end

    test "a plain `plan \"render foo\"` idea is still authoring, not the subcommand" do
      # `render` only reserves the subcommand when it is a SEPARATE token; a quoted
      # idea that merely starts with the word render stays authoring.
      assert {:propose, "render foo", _opts} = CLI.parse(["plan", "render foo"])
    end
  end

  # --- render end-to-end -----------------------------------------------------

  describe "run/2 — plan render" do
    test "renders a seeded roadmap: banner, [x] for the converged goal, [ ] otherwise",
         %{tmp_dir: tmp} do
      path = write_chain_roadmap(tmp)
      seed_converged("foundation")

      {out, code} = render_cli(["plan", "render", path])

      assert code == 0
      assert out =~ "GENERATED"
      assert out =~ "DO NOT HAND-EDIT"
      assert out =~ "- [x] `foundation`"
      assert out =~ "- [ ] `api`"
      assert out =~ "- [ ] `ui`"
      assert out =~ "**Progress:** 1 / 3 goals converged (33%)"
    end

    test "rendered waves match `apply <roadmap> --explain`'s frontiers", %{tmp_dir: tmp} do
      path = write_chain_roadmap(tmp)

      {explain_out, 0} = render_cli(["apply", path, "--workspace", tmp, "--explain", "--json"])
      frontiers = Jason.decode!(explain_out)["frontiers"]
      assert frontiers == [["foundation"], ["api"], ["ui"]]

      {render_out, 0} = render_cli(["plan", "render", path])

      rendered_ids =
        Regex.scan(~r/^- \[[ x]\] `([a-z]+)`/m, render_out) |> Enum.map(fn [_, id] -> id end)

      assert rendered_ids == List.flatten(frontiers)
    end

    test "a re-render after a verdict changes reflects the new state", %{tmp_dir: tmp} do
      path = write_chain_roadmap(tmp)

      {before, 0} = render_cli(["plan", "render", path])
      assert before =~ "- [ ] `foundation`"

      seed_converged("foundation")

      {after_, 0} = render_cli(["plan", "render", path])
      assert after_ =~ "- [x] `foundation`"
      # api/ui are still pending — only foundation's line flipped.
      assert after_ =~ "- [ ] `api`"
    end

    test "--out writes the markdown to a file and keeps stdout clean", %{tmp_dir: tmp} do
      path = write_chain_roadmap(tmp)
      out_path = Path.join(tmp, "PLAN.md")

      {stdout, code} = render_cli(["plan", "render", path, "--out", out_path])

      assert code == 0
      assert stdout == ""
      written = File.read!(out_path)
      assert written =~ "GENERATED"
      assert written =~ "- [ ] `foundation`"
    end

    test "an unloadable roadmap is a non-zero error, not a crash", %{tmp_dir: tmp} do
      bad = Path.join(tmp, "cyclic.roadmap.toml")

      File.write!(bad, """
      [[goals]]
      id = "a"
      path = "a.goal.toml"
      needs = ["b"]

      [[goals]]
      id = "b"
      path = "b.goal.toml"
      needs = ["a"]
      """)

      {_out, code} = render_cli(["plan", "render", bad])
      assert code == 1
    end
  end

  # --- fixtures + helpers ----------------------------------------------------

  # foundation -> api -> ui, path members (each a minimal valid goal whose id
  # equals its node id, so the read-model goal_ref matches).
  defp write_chain_roadmap(tmp) do
    dir = Path.join(tmp, "chain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for id <- ~w(foundation api ui),
        do: File.write!(Path.join(dir, "#{id}.goal.toml"), goal_toml(id))

    path = Path.join(dir, "pipeline.roadmap.toml")

    File.write!(path, """
    [[goals]]
    id = "foundation"
    path = "foundation.goal.toml"

    [[goals]]
    id = "api"
    path = "api.goal.toml"
    needs = ["foundation"]

    [[goals]]
    id = "ui"
    path = "ui.goal.toml"
    needs = ["api"]
    """)

    path
  end

  defp goal_toml(id) do
    """
    id = "#{id}"
    name = "goal #{id}"

    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    """
  end

  defp seed_converged(goal_ref) do
    vector = PredicateVector.new(%{p: PredicateResult.pass()})

    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: 0,
        predicate_vector: vector,
        converged: true
      })
  end

  defp render_cli(argv) do
    ref = make_ref()
    me = self()
    out = capture_io(fn -> send(me, {ref, CLI.run(argv, [])}) end)

    receive do
      {^ref, code} -> {out, code}
    after
      0 -> flunk("expected an exit code")
    end
  end
end
