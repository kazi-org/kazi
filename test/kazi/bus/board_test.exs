defmodule Kazi.Bus.BoardTest do
  @moduledoc """
  T55.4 (ADR-0073 decision point 1): the board's PURE projection -- last-value
  collapse, digest-inherited bounding/stubbing, and the idempotent roster shape,
  all without a live daemon.
  """
  use ExUnit.Case, async: true

  alias Kazi.Bus.Board
  alias Kazi.Bus.Digest

  defp fact(topic, text, id, extra \\ %{}) do
    Map.merge(
      %{
        kind: "fact",
        topic: topic,
        text: text,
        sev: "info",
        id: id,
        session: "s1",
        machine: "host",
        ts: "2026-07-16T00:00:00Z"
      },
      extra
    )
  end

  describe "render/2 fact projection" do
    test "three facts on one topic collapse to ONE current line -- the latest value" do
      facts = [
        fact("ci", "main is red", 10),
        fact("ci", "still red", 20),
        fact("ci", "main is green", 30)
      ]

      board = Board.render(facts, [])

      assert board["total_facts"] == 1
      assert [line] = board["facts"]
      assert line["topic"] == "ci"
      assert line["text"] == "main is green"
      assert line["id"] == 30
    end

    test "distinct topics each render their own latest line" do
      facts = [
        fact("ci", "red", 1),
        fact("deploy", "rolling", 2),
        fact("ci", "green", 3)
      ]

      board = Board.render(facts, [])

      assert board["total_facts"] == 2
      by_topic = Map.new(board["facts"], &{&1["topic"], &1["text"]})
      assert by_topic == %{"ci" => "green", "deploy" => "rolling"}
    end

    test "an oversize fact body renders as a stub via the digest stub rule, never verbatim" do
      big = String.duplicate("x", Digest.render_threshold_bytes() + 1)
      board = Board.render([fact("doc", big, 5)], [])

      assert [line] = board["facts"]
      assert line["type"] == "stub"
      assert line["id"] == 5
      assert line["bytes"] == byte_size(big)
      refute Map.has_key?(line, "text")
    end

    test "a body at the threshold still renders verbatim" do
      body = String.duplicate("y", Digest.render_threshold_bytes())
      board = Board.render([fact("doc", body, 6)], [])

      assert [line] = board["facts"]
      assert line["type"] == "verbatim"
      assert line["text"] == body
    end

    test "the fact section is bounded regardless of topic count, tail folds into one overflow" do
      facts = for i <- 1..500, do: fact("topic-#{i}", "v#{i}", i)

      board = Board.render(facts, [])

      assert board["total_facts"] == 500
      assert length(board["facts"]) == Digest.max_lines()
      assert List.last(board["facts"])["type"] == "overflow"

      counted =
        board["facts"]
        |> Enum.map(fn line -> line["count"] || 1 end)
        |> Enum.sum()

      assert counted == 500
    end

    test "a facts-only board renders an empty roster and empty fact list cleanly" do
      assert Board.render([], []) == %{
               "facts" => [],
               "roster" => [],
               "total_facts" => 0,
               "total_sessions" => 0
             }
    end
  end

  describe "render/2 roster projection" do
    test "renders stable identity fields (name, team, machine, liveness), sorted by session" do
      roster = [
        %{
          "session" => "zeta",
          "name" => "reviewer",
          "team" => "wave1",
          "machine" => "hostB",
          "liveness" => "active",
          "age_s" => 3,
          "seen_s" => 3,
          "inbox" => 0,
          "cwd" => "/tmp"
        },
        %{
          "session" => "alpha",
          "name" => nil,
          "team" => nil,
          "machine" => "hostA",
          "liveness" => "idle",
          "age_s" => 40
        }
      ]

      board = Board.render([], roster)

      assert board["total_sessions"] == 2
      assert [first, second] = board["roster"]
      assert first["session"] == "alpha"
      assert second["session"] == "zeta"

      assert second == %{
               "session" => "zeta",
               "name" => "reviewer",
               "team" => "wave1",
               "machine" => "hostB",
               "liveness" => "active"
             }
    end

    test "the roster projection drops age/heartbeat fields so back-to-back boards are identical" do
      base = %{
        "session" => "s1",
        "name" => "a",
        "team" => nil,
        "machine" => "h",
        "liveness" => "active"
      }

      earlier = Board.render([], [Map.merge(base, %{"age_s" => 1, "seen_s" => 1})])
      later = Board.render([], [Map.merge(base, %{"age_s" => 99, "seen_s" => 99})])

      assert earlier == later
    end
  end
end
