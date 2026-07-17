defmodule Kazi.Bus.Digest do
  @moduledoc """
  T51.2 (ADR-0067 decision point 4) / T55.1 (ADR-0072): `kazi bus read`'s
  rendering rules, kept in ONE pure module so a later task (T55.7, server-side
  aggregation) can move them without touching `Kazi.Bus` or the CLI.

  Two surfaces:

    * `summarize/1` -- the human TTY digest (unchanged since T51.2): directed
      messages (`kind == "msg"`, i.e. `bus tell`) and `sev == "interrupt"`
      posts render VERBATIM, one line each -- an operator must never miss a
      directed or urgent message inside a summary. Everything else collapses
      into one `<count> <kind>/<topic>` digest line per distinct
      `{kind, topic}` pair.

    * `render/1` -- the MACHINE digest (ADR-0072 d1/d2/d6): the bounded,
      structured shape `--json` and the `kazi_bus_*` MCP tools return by
      default. Same verbatim rule, plus two render-time bounds the TTY line
      format never needed stated: a body over `render_threshold_bytes/0`
      (1024 bytes) NEVER renders verbatim -- it collapses to a one-line
      stub carrying id/kind/topic/provenance/byte-size, for EVERY kind
      including directed/interrupt -- and the whole digest is at most
      `max_lines/0` lines regardless of backlog depth (the tail past the
      bound folds into one exact-count `overflow` line). Every line carries
      the message's JetStream stream sequence as its public `id`, so
      anything a digest names stays dereferenceable.
  """

  # ADR-0072 decision 2: the render threshold. A message body over this many
  # bytes never renders verbatim in a digest -- it becomes a one-line stub.
  # This bounds RENDER cost only; the 64 KiB post cap and the stream limits
  # (Kazi.Bus / Kazi.Bus.Provision) are untouched.
  @render_threshold_bytes 1024

  # ADR-0072 decision 6: the digest's hard line bound. "A thousand-message
  # backlog costs the same as forty lines" -- an acceptance criterion, not an
  # aspiration.
  @max_lines 40

  @typedoc "One bus message as `Kazi.Bus.read/1` returns it."
  @type message :: %{
          required(:kind) => String.t(),
          required(:topic) => String.t() | nil,
          required(:text) => String.t(),
          required(:sev) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "One string-keyed digest line: verbatim, stub, count, or overflow."
  @type line :: %{required(String.t()) => term()}

  @doc "The verbatim render threshold in bytes (ADR-0072 decision 2)."
  @spec render_threshold_bytes() :: pos_integer()
  def render_threshold_bytes, do: @render_threshold_bytes

  @doc "The digest's maximum line count (ADR-0072 decision 6)."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc """
  Renders ONE message as a single line: verbatim (its full `text`, plus
  id/kind/topic/provenance) when its body fits `render_threshold_bytes/0`, or a
  `"stub"` (the same provenance WITHOUT `text`) when it is over the threshold.

  This is the ADR-0072 decision 2 stub rule as a reusable per-message unit --
  the board (`Kazi.Bus.Board`) renders each topic's current-value fact through
  it so the oversize-becomes-stub decision lives in ONE place, never
  reimplemented against the raw threshold.
  """
  @spec line(message()) :: line()
  def line(msg) do
    if oversize?(msg), do: stub_line(msg), else: verbatim_line(msg)
  end

  @doc """
  T55.6 (ADR-0072 decision 3): shape a single message fetched by `bus get`
  for a rendering surface. The full body always lives in `message["text"]`
  (`Kazi.Bus.get/2` never truncates); this only decides how much of it a
  surface shows.

  `full?` true returns the body unabridged with `"truncated" => false`.
  `full?` false bounds `"text"` to `render_threshold_bytes/0` -- the SAME
  1024-byte threshold that collapsed the body into a stub in the first place
  -- on a valid UTF-8 boundary, and sets `"truncated" => true` when it cut
  anything, so a default `get` stays cheap and the `--full` escape is what
  spends the context. A body already within the threshold is returned whole
  with `"truncated" => false` regardless of `full?`.
  """
  @spec get_view(map(), boolean()) :: map()
  def get_view(message, full?) do
    text = message["text"] || ""

    if full? or byte_size(text) <= @render_threshold_bytes do
      Map.put(message, "truncated", false)
    else
      message
      |> Map.put("text", valid_utf8_prefix(binary_part(text, 0, @render_threshold_bytes)))
      |> Map.put("truncated", true)
    end
  end

  # A byte-length truncation can split a multi-byte UTF-8 codepoint, which
  # would make the preview invalid UTF-8 and break JSON encoding. Trim up to
  # the last 3 bytes until the prefix is valid.
  defp valid_utf8_prefix(<<>>), do: <<>>

  defp valid_utf8_prefix(bin) do
    if String.valid?(bin),
      do: bin,
      else: valid_utf8_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end

  @doc """
  Splits `messages` into verbatim lines (directed `msg` or `sev: "interrupt"`)
  and digest lines (`<count> <kind>/<topic>`, grouped, most-frequent first).
  Returns `%{verbatim: [String.t()], digest: [String.t()]}`; both empty for `[]`.
  """
  @spec summarize([message()]) :: %{verbatim: [String.t()], digest: [String.t()]}
  def summarize(messages) when is_list(messages) do
    {verbatim_msgs, digest_msgs} = Enum.split_with(messages, &verbatim?/1)

    verbatim =
      Enum.map(verbatim_msgs, fn msg -> "[#{msg.kind}] #{msg.text}" end)

    digest =
      digest_msgs
      |> Enum.group_by(fn msg -> {msg.kind, msg.topic} end)
      |> Enum.map(fn {{kind, topic}, group} -> {length(group), kind, topic} end)
      |> Enum.sort_by(fn {count, _kind, _topic} -> -count end)
      |> Enum.map(fn {count, kind, topic} -> "#{count} #{kind}/#{topic || "_"}" end)

    %{verbatim: verbatim, digest: digest}
  end

  @doc """
  The bounded machine digest (ADR-0072 d1/d2/d6): what every `--json` /
  MCP bus read returns by default.

  Returns `%{"total" => n, "lines" => [line]}` with at most `max_lines/0`
  lines and `total` the exact message count. Line shapes (all string-keyed,
  JSON-ready):

    * `"verbatim"` -- a directed (`kind: "msg"`) or `sev: "interrupt"`
      message whose body fits `render_threshold_bytes/0`: id, kind, topic,
      sev, session, machine, ts, bytes, and the full `text`.
    * `"stub"` -- ANY message whose body exceeds the threshold (including
      directed/interrupt): the same fields WITHOUT `text`. The body stays
      in the stream, addressable by `id`.
    * `"count"` -- everything else, collapsed per `{kind, topic}` with an
      exact `count` and the group's `first_id`/`last_id`, most-frequent
      first.
    * `"overflow"` -- at most one, always last: when even the line set
      would exceed `max_lines/0`, the tail folds into one line carrying the
      exact `count` of messages it represents and their `first_id`/`last_id`.
  """
  @spec render([message()]) :: %{required(String.t()) => term()}
  def render(messages) when is_list(messages) do
    {line_msgs, grouped_msgs} =
      Enum.split_with(messages, fn msg -> oversize?(msg) or verbatim?(msg) end)

    head_lines =
      Enum.map(line_msgs, fn msg ->
        if oversize?(msg), do: stub_line(msg), else: verbatim_line(msg)
      end)

    count_lines =
      grouped_msgs
      |> Enum.group_by(fn msg -> {msg.kind, msg.topic} end)
      |> Enum.map(fn {{kind, topic}, group} -> count_line(kind, topic, group) end)
      |> Enum.sort_by(fn line -> -line["count"] end)

    %{"total" => length(messages), "lines" => bound(head_lines ++ count_lines)}
  end

  defp bound(lines) when length(lines) <= @max_lines, do: lines

  defp bound(lines) do
    {kept, dropped} = Enum.split(lines, @max_lines - 1)
    kept ++ [overflow_line(dropped)]
  end

  defp verbatim_line(msg) do
    msg
    |> provenance()
    |> Map.merge(%{"type" => "verbatim", "text" => msg.text})
  end

  defp stub_line(msg) do
    Map.put(provenance(msg), "type", "stub")
  end

  defp provenance(msg) do
    %{
      "id" => Map.get(msg, :id),
      "kind" => msg.kind,
      "topic" => msg.topic,
      "sev" => msg.sev,
      "session" => Map.get(msg, :session),
      "machine" => Map.get(msg, :machine),
      "ts" => Map.get(msg, :ts),
      "bytes" => byte_size(msg.text)
    }
  end

  defp count_line(kind, topic, group) do
    ids = for msg <- group, is_integer(Map.get(msg, :id)), do: msg.id

    %{
      "type" => "count",
      "kind" => kind,
      "topic" => topic,
      "count" => length(group),
      "first_id" => List.first(ids),
      "last_id" => List.last(ids)
    }
  end

  # The exact-count fold for a digest whose LINE set would itself exceed the
  # bound: `count` is the number of MESSAGES the dropped lines represented
  # (a count line contributes its own count), never the number of lines.
  defp overflow_line(dropped) do
    ids =
      dropped
      |> Enum.flat_map(fn line -> [line["id"], line["first_id"], line["last_id"]] end)
      |> Enum.filter(&is_integer/1)

    %{
      "type" => "overflow",
      "count" => Enum.sum(Enum.map(dropped, fn line -> line["count"] || 1 end)),
      "first_id" => Enum.min(ids, fn -> nil end),
      "last_id" => Enum.max(ids, fn -> nil end)
    }
  end

  defp oversize?(msg), do: byte_size(msg.text) > @render_threshold_bytes

  defp verbatim?(%{kind: "msg"}), do: true
  defp verbatim?(%{sev: "interrupt"}), do: true
  defp verbatim?(_msg), do: false
end
