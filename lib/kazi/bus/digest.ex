defmodule Kazi.Bus.Digest do
  @moduledoc """
  T51.2 (ADR-0067 decision point 4): `kazi bus read`'s MVP rendering rule, kept
  in ONE pure function so a later task (T51.4, server-side aggregation) can
  move it without touching `Kazi.Bus` or the CLI.

  Directed messages (`kind == "msg"`, i.e. `bus tell`) and `sev == "interrupt"`
  posts render VERBATIM, one line each -- an operator must never miss a
  directed or urgent message inside a summary. Everything else collapses into
  one `<count> <kind>/<topic>` digest line per distinct `{kind, topic}` pair.
  """

  @typedoc "One bus message as `Kazi.Bus.read/1` returns it."
  @type message :: %{
          required(:kind) => String.t(),
          required(:topic) => String.t() | nil,
          required(:text) => String.t(),
          required(:sev) => String.t(),
          optional(atom()) => term()
        }

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

  defp verbatim?(%{kind: "msg"}), do: true
  defp verbatim?(%{sev: "interrupt"}), do: true
  defp verbatim?(_msg), do: false
end
