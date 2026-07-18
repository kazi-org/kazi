defmodule Kazi.Daemon.WriteTest do
  @moduledoc """
  T52.3 (ADR-0068 decision 1): the daemon's server-side single-writer `write`
  op. Tier 2 -- real SQLite boundary through the sandbox `Kazi.Repo`: a batch
  is applied atomically, a mid-batch constraint violation rolls the WHOLE batch
  back, an over-buffer line is refused before any write, a raw FTS statement
  round-trips, and an unknown `kind` fails cleanly without crashing.
  """
  use ExUnit.Case, async: false

  alias Kazi.Daemon.Control
  alias Kazi.Daemon.Probe
  alias Kazi.Daemon.Write
  alias Kazi.ReadModel.Iteration
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp insert_entry(goal_ref, index) do
    %{
      "kind" => "insert",
      "schema" => "Kazi.ReadModel.Iteration",
      "fields" => %{
        "goal_ref" => goal_ref,
        "iteration_index" => index,
        "predicate_vector" => %{},
        "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  defp count(goal_ref) do
    import Ecto.Query
    Repo.aggregate(from(i in Iteration, where: i.goal_ref == ^goal_ref), :count)
  end

  test "a 3-entry batch applies all three atomically and replies applied: 3" do
    request = %{"op" => "write", "batch" => Enum.map(0..2, &insert_entry("g-atomic", &1))}

    assert %{"ok" => true, "applied" => 3} = Write.handle(request, repo: Repo)
    assert count("g-atomic") == 3
  end

  test "a batch whose 2nd entry violates a constraint rolls back ALL three (ok:false)" do
    # entries 0, 1, 1 -- the third re-uses index 1, violating the
    # (goal_ref, iteration_index) unique constraint mid-batch.
    batch = [insert_entry("g-roll", 0), insert_entry("g-roll", 1), insert_entry("g-roll", 1)]
    request = %{"op" => "write", "batch" => batch}

    assert %{"ok" => false} = reply = Write.handle(request, repo: Repo)
    assert reply["error"] != nil
    # Not a partial batch: entries 0 and 1 must NOT persist either.
    assert count("g-roll") == 0
  end

  test "a request line at/over socket_buffer/0 is refused with a named error, not applied" do
    # A field padded past the 1 MiB socket buffer -> the encoded line is over
    # the bound and would be silently truncated in transit (L-0052).
    big = String.duplicate("x", Probe.socket_buffer())
    request = %{"op" => "write", "batch" => [Map.put(insert_entry("g-big", 0), "pad", big)]}

    assert %{"ok" => false, "error" => "request_too_large"} = Write.handle(request, repo: Repo)
    assert count("g-big") == 0
  end

  test "a raw-SQL (FTS) write plan round-trips and persists" do
    root = "/tmp/write-test-#{System.unique_integer([:positive])}"

    request = %{
      "op" => "write",
      "batch" => [
        %{
          "kind" => "sql",
          "sql" =>
            "INSERT INTO memory_chunks_fts (workspace_root, path, heading, line_start, line_end, body) VALUES (?, ?, ?, ?, ?, ?)",
          "params" => [root, "a.md", "H", 1, 2, "hello world"]
        }
      ]
    }

    assert %{"ok" => true, "applied" => 1} = Write.handle(request, repo: Repo)

    {:ok, %{rows: rows}} =
      Repo.query("SELECT body FROM memory_chunks_fts WHERE workspace_root = ?", [root])

    assert rows == [["hello world"]]
  end

  test "an unknown kind replies ok:false without crashing the connection" do
    request = %{"op" => "write", "batch" => [%{"kind" => "teleport", "schema" => "Whatever"}]}

    assert %{"ok" => false, "error" => "unknown_kind: teleport"} =
             Write.handle(request, repo: Repo)
  end

  test "an update_all plan mutates only the matched rows" do
    Write.handle(%{"op" => "write", "batch" => [insert_entry("g-upd", 0)]}, repo: Repo)

    update = %{
      "op" => "write",
      "batch" => [
        %{
          "kind" => "update_all",
          "schema" => "Kazi.ReadModel.Iteration",
          "filters" => %{"goal_ref" => "g-upd", "iteration_index" => 0},
          "changes" => %{"converged" => true}
        }
      ]
    }

    assert %{"ok" => true, "applied" => 1} = Write.handle(update, repo: Repo)

    import Ecto.Query
    row = Repo.one(from(i in Iteration, where: i.goal_ref == "g-upd"))
    assert row.converged == true
  end

  test "Control routes the write op to Kazi.Daemon.Write" do
    request = %{"op" => "write", "batch" => [insert_entry("g-control", 0)]}

    assert %{"ok" => true, "applied" => 1} = Control.handle(request, repo: Repo)
    assert count("g-control") == 1
  end

  test "a missing batch is a clean failure, not a crash" do
    assert %{"ok" => false, "error" => "missing_batch"} =
             Write.handle(%{"op" => "write"}, repo: Repo)
  end
end
