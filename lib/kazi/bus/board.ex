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
        "total_sessions" => m,
        "attention" => [entry],  # T60.3: sessions waiting on a human, oldest first
        "total_attention" => k
      }

  `facts` are collapsed to the LATEST value per topic (highest `id` wins) before
  rendering, so posting three facts on one topic yields ONE current line -- the
  last, never three. `total_facts` counts distinct topics, so an `overflow`
  fact line never hides how many topics the board actually holds.

  ## Attention (T60.3, issue #1156)

  `"attention"` is computed from the SAME collapsed per-topic facts, filtered
  to every topic starting with `"attention-"` whose current text starts with
  `"waiting-on-operator"` (a `"none"` clear -- `Kazi.Bus.Hook.turn/1` posts one
  every turn -- excludes the session, which is the auto-clear-on-unblock: the
  moment a session's next turn runs, it drops out of this section for free).
  Each entry is `%{"session", "machine", "summary", "since", "age_s"}`, sorted
  oldest-waiting-first (ordering degrades gracefully -- a fact whose `since`
  timestamp does not parse sorts last rather than raising).
  """
  @spec render([fact()], [roster_entry()]) :: %{required(String.t()) => term()}
  def render(facts, roster) when is_list(facts) and is_list(roster) do
    topics = collapse_latest(facts)

    fact_lines =
      topics
      |> Enum.map(&Digest.line/1)
      |> bound()

    attention = render_attention(topics, roster)

    %{
      "facts" => fact_lines,
      "roster" => render_roster(roster),
      "total_facts" => length(topics),
      "total_sessions" => length(roster),
      "attention" => attention,
      "total_attention" => length(attention)
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

  @attention_prefix "attention-"
  @waiting_prefix "waiting-on-operator"

  # T60.3: the raw (unstubbed, atom-keyed) collapsed facts are the input --
  # the attention text is always short, so it never hits the digest's
  # stub/overflow bound, but reading it BEFORE `Digest.line/1` means this
  # never depends on that render happening not to have stubbed it anyway.
  # Roster-gated (#1567): the auto-clear is the waiting session's OWN next
  # turn-hook, so a session that dies mid-wait leaves an immortal
  # `waiting-on-operator` fact. A session with no live presence cannot be
  # waiting on anyone -- drop its entry instead of rendering a stale card.
  # Alive-but-idle sessions stay: a waiting session is by definition idle.
  # Roster ids are matched through the same sanitizer the topic was built
  # with (`Kazi.Bus.attention_topic/1`), so an id that needed sanitizing
  # still gates its own topic.
  defp render_attention(topics, roster) do
    live =
      for %{"session" => session} <- roster,
          is_binary(session) and session != "",
          into: MapSet.new(),
          do: Kazi.Bus.attention_topic(session)

    topics
    |> Enum.filter(&attention_fact?/1)
    |> Enum.filter(&MapSet.member?(live, &1[:topic]))
    |> Enum.map(&attention_entry/1)
    |> Enum.sort_by(& &1["age_s"], &age_desc/2)
  end

  defp attention_fact?(%{topic: @attention_prefix <> _, text: @waiting_prefix <> _}), do: true
  defp attention_fact?(_fact), do: false

  defp attention_entry(%{topic: @attention_prefix <> session, text: text} = fact) do
    {summary, since} = parse_waiting(text)

    %{
      "session" => session,
      "machine" => fact[:machine],
      "summary" => summary,
      "since" => since,
      "age_s" => age_s(since)
    }
  end

  # `"waiting-on-operator: <summary> (since <ts>)"` -- the normal, summarized
  # form the `notification` hook posts when it read a message off stdin.
  defp parse_waiting(@waiting_prefix <> ": " <> rest) do
    case Regex.run(~r/^(.*) \(since (.+)\)$/s, rest) do
      [_, summary, since] -> {summary, since}
      nil -> {rest, nil}
    end
  end

  # `"waiting-on-operator (since <ts>)"` -- the degraded form (no stdin
  # summary available): no colon, so no summary text to split out.
  defp parse_waiting(@waiting_prefix <> " (since " <> rest) do
    {@waiting_prefix, String.trim_trailing(rest, ")")}
  end

  defp parse_waiting(_text), do: {@waiting_prefix, nil}

  defp age_s(nil), do: nil

  defp age_s(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _offset} -> DateTime.diff(DateTime.utc_now(), dt)
      {:error, _reason} -> nil
    end
  end

  # Oldest-waiting-first: the LARGER age sorts first. A fact whose `since`
  # never parsed (`age_s` is `nil`) sorts last rather than raising or crowding
  # out entries whose age is actually known.
  defp age_desc(nil, nil), do: true
  defp age_desc(nil, _b), do: false
  defp age_desc(_a, nil), do: true
  defp age_desc(a, b), do: a >= b

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
