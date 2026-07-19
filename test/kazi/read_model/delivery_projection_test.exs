defmodule Kazi.ReadModel.DeliveryProjectionTest do
  @moduledoc """
  T67.2 (ADR-0079): the git-derived delivery projection. Builds a throwaway
  fixture git repo (two sessions' trailers, three ticked tasks, two merged PRs),
  projects it, and asserts the expected rows land exactly once across repeated
  scans, each carrying the join keys ADR-0079 §3 names. Also covers the
  trailer-stripped case (nil session, row still projected) and the incremental
  `:since` cursor. Hermetic: git-only, no network, no daemon (the daemon-write
  seam is pinned separately in `delivery_projection_socket_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.{DeliveryEvent, DeliveryProjection}
  alias Kazi.Repo

  import Ecto.Query, only: [from: 2]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # A throwaway git repo the projection can scan; cleaned up on exit.
  defp init_repo do
    dir = Path.join(System.tmp_dir!(), "kazi_delivery_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs/plans"))
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "fixture@example.test"])
    git!(dir, ["config", "user.name", "fixture"])
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Append lines to a plan file and commit, optionally with a Claude-Session
  # trailer in the message body (the ADR's optional enrichment).
  defp commit(dir, file, added_lines, subject, opts \\ []) do
    path = Path.join(dir, file)

    existing =
      case File.read(path) do
        {:ok, content} -> content
        _ -> ""
      end

    File.write!(path, [existing, added_lines, "\n"])
    git!(dir, ["add", "-A"])

    args =
      ["commit", "-q", "-m", subject] ++
        case opts[:session] do
          nil -> []
          token -> ["-m", "Claude-Session: https://claude.ai/code/#{token}"]
        end

    git!(dir, args)
    dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp count(kind),
    do: Repo.aggregate(from(d in DeliveryEvent, where: d.kind == ^kind), :count, :id)

  defp get_tick(task_id), do: Repo.get_by(DeliveryEvent, kind: "task_tick", task_id: task_id)

  test "projects three ticks + two PR merges, exactly once across repeated scans, with join keys" do
    dir = init_repo()

    # Session 1 ticks T99.1 (PR #100).
    commit(
      dir,
      "docs/plans/E99.md",
      "- [x] T99.1 first task  Done: 2026-07-18 (PR #100)",
      "docs(plan): tick T99.1",
      session: "session_aaa"
    )

    # Session 2 ticks T99.2 and T99.3, both under PR #101.
    commit(
      dir,
      "docs/plans/E99.md",
      "- [x] T99.2 second task  Done: 2026-07-19 (PR #101)\n- [x] T99.3 third task  Done: 2026-07-19 (PR #101)",
      "docs(plan): tick T99.2 and T99.3",
      session: "session_bbb"
    )

    assert {:ok, summary} = DeliveryProjection.project(dir, repo_slug: "acme/widget")
    assert summary.task_ticks == 3
    assert summary.pr_merges == 2

    # Three task ticks, two PR merges.
    assert count("task_tick") == 3
    assert count("pr_merge") == 2

    # Row-level join keys (ADR-0079 §3).
    t1 = get_tick("T99.1")
    assert t1.epic == "E99"
    assert t1.done_on == ~D[2026-07-18]
    assert t1.pr_number == 100
    assert t1.repo_slug == "acme/widget"
    assert t1.trailer_session_id == "session_aaa"
    assert is_binary(t1.merge_commit_sha)
    assert %DateTime{} = t1.merged_at
    # No kazi run backs a git-derived tick -> honest fleet-level (nil session).
    assert is_nil(t1.session_uuid)
    assert is_nil(t1.goal_ref)

    # Two sessions' trailers are attributed distinctly.
    assert get_tick("T99.2").trailer_session_id == "session_bbb"
    assert get_tick("T99.3").trailer_session_id == "session_bbb"

    # The two distinct PRs projected as pr_merge rows.
    prs = Repo.all(from(d in DeliveryEvent, where: d.kind == "pr_merge", select: d.pr_number))
    assert Enum.sort(prs) == [100, 101]

    # Idempotent re-scan: same history in -> same rows, no duplicates.
    assert {:ok, _} = DeliveryProjection.project(dir, repo_slug: "acme/widget")
    assert count("task_tick") == 3
    assert count("pr_merge") == 2
    assert Repo.aggregate(DeliveryEvent, :count, :id) == 5
  end

  test "a trailer-stripped commit still projects the row, with nil session attribution" do
    dir = init_repo()

    commit(
      dir,
      "docs/plans/E88.md",
      "- [x] T88.1 stripped task  Done: 2026-07-18 (PR #200)",
      "docs(plan): tick T88.1 (no trailer)"
    )

    assert {:ok, summary} = DeliveryProjection.project(dir)
    assert summary.task_ticks == 1

    row = get_tick("T88.1")
    assert row.pr_number == 200
    assert is_nil(row.trailer_session_id)
    assert is_nil(row.session_uuid)
  end

  test "the :since cursor bounds the scan to new commits only" do
    dir = init_repo()

    first =
      commit(dir, "docs/plans/E77.md", "- [x] T77.1 a  Done: 2026-07-18 (PR #300)", "tick T77.1")

    # A full scan sees the first tick; the cursor points at its landing commit.
    assert {:ok, _} = DeliveryProjection.project(dir)
    assert DeliveryProjection.last_seen_commit() == first

    # A second commit after the cursor is the only thing an incremental scan reads.
    commit(dir, "docs/plans/E77.md", "- [x] T77.2 b  Done: 2026-07-19 (PR #301)", "tick T77.2")

    assert {:ok, summary} = DeliveryProjection.project(dir, since: first)
    assert summary.commits == 1
    assert summary.task_ticks == 1
    assert count("task_tick") == 2
  end
end
