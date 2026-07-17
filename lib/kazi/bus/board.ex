defmodule Kazi.Bus.Board do
  @moduledoc """
  T55.4 (ADR-0073 decision point 1): the board's PURE projection -- the shape
  `kazi bus board` (and its `kazi_bus_board` MCP twin) render from the two
  live-state inputs `Kazi.Bus.board/1` gathers: the last-value `fact` per topic
  and the current roster.

  A stream answers "what changed since I last looked"; a board answers "what is
  true right now". So this module renders CURRENT STATE, not a delta or a
  history: one line per fact topic carrying its latest value, and one line per
  live roster session carrying its addressable identity. It consumes nothing and
  keeps no cursor -- the impurity (reading the stream and the presence bucket)
  lives in `Kazi.Bus`; everything here is a deterministic function of its inputs,
  so a session may board every turn and two boards over the same state render
  identically.

  Two bounds, both inherited from the digest (`Kazi.Bus.Digest`, ADR-0072) so a
  board can never cost more attention than a read:

    * per topic, an oversize fact body collapses to a one-line stub via
      `Kazi.Bus.Digest.line/1` -- the SAME stub rule, not a second copy of it;
    * the fact section is at most `Kazi.Bus.Digest.max_lines/0` lines regardless
      of topic count, the tail folding into one exact-count `overflow` line.

  The roster is rendered from stable identity fields only (session id, name,
  team, machine, liveness) and ordered by session id -- deliberately NOT by the
  age/heartbeat fields `who` sorts on, so the projection is idempotent: the same
  set of live sessions renders byte-identically on back-to-back boards even as
  their heartbeats tick.
  """

  alias Kazi.Bus.Digest

  @typedoc "One fact message as `Kazi.Bus.board/1` collects it (a `read`-shaped map)."
  @type fact :: %{optional(atom()) => term()}

  @typedoc "One roster entry as `Kazi.Bus.roster/1` returns it (string-keyed)."
  @type roster_entry :: %{required(String.t()) => term()}

  @doc """
  Projects `facts` (a `read`-shaped message list) and `roster` (a `who`-shaped
  entry list) into the board's bounded, JSON-ready shape:

      %{
        "facts" => [line],       # last value per topic, stubbed + bounded
        "roster" => [entry],     # stable identity per live session
        "total_facts" => n,      # distinct fact topics before bounding
        "total_sessions" => m
      }

  `facts` are collapsed to the LATEST value per topic (highest `id` wins) before
  rendering, so posting three facts on one topic yields ONE current line -- the
  last, never three. `total_facts` counts distinct topics, so an `overflow`
  fact line never hides how many topics the board actually holds.
  """
  @spec render([fact()], [roster_entry()]) :: %{required(String.t()) => term()}
  def render(facts, roster) when is_list(facts) and is_list(roster) do
    topics = collapse_latest(facts)

    fact_lines =
      topics
      |> Enum.map(&Digest.line/1)
      |> bound()

    %{
      "facts" => fact_lines,
      "roster" => render_roster(roster),
      "total_facts" => length(topics),
      "total_sessions" => length(roster)
    }
  end

  # One entry per topic: the message with the highest stream-seq `id` (the
  # latest post). `id` is monotone in publish order, so it decides "latest"
  # without a timestamp parse; a fact with no id (never round-tripped) sorts
  # last and only wins a topic that has nothing newer.
  defp collapse_latest(facts) do
    facts
    |> Enum.group_by(&topic_key/1)
    |> Enum.map(fn {_topic, group} -> Enum.max_by(group, &(&1[:id] || -1)) end)
    |> Enum.sort_by(&topic_key/1)
  end

  defp topic_key(fact), do: fact[:topic] || "_"

  # ADR-0072 decision 6's bound, applied to the fact section: a thousand-topic
  # board costs the same as forty lines. The tail past the bound folds into one
  # exact-count overflow line (mirrors `Kazi.Bus.Digest`'s own fold).
  defp bound(lines) do
    max = Digest.max_lines()

    if length(lines) <= max do
      lines
    else
      {kept, dropped} = Enum.split(lines, max - 1)
      kept ++ [%{"type" => "overflow", "count" => length(dropped)}]
    end
  end

  # The roster projection: stable identity fields only, ordered by session id.
  # `age_s`/`seen_s` are deliberately dropped -- they tick every second and
  # would make an otherwise-unchanged board render differently on every call.
  defp render_roster(roster) do
    roster
    |> Enum.map(fn entry ->
      %{
        "session" => entry["session"],
        "name" => entry["name"],
        "team" => entry["team"],
        "machine" => entry["machine"],
        "liveness" => entry["liveness"]
      }
    end)
    |> Enum.sort_by(& &1["session"])
  end
end
