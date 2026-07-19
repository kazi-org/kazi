defmodule Kazi.Velocity.SessionCountersWireShapeTest do
  @moduledoc """
  T67.3 HEADLINE ACCEPTANCE (ADR-0079 R-E67-3): the collector NEVER emits
  transcript content. The wire payload — both the bus `fact` text and the
  read-model row attrs — contains ONLY the closed counter whitelist plus session
  identity. No free-text/content field (prompt text, tool names, file paths) can
  cross the wire, pinned here so any future field that leaks content fails this
  test.
  """
  use ExUnit.Case, async: true

  alias Kazi.Velocity.{Counters, SessionCollector, TranscriptParser}

  @fixtures Path.expand("../../support/fixtures/velocity", __DIR__)

  # Everything content-bearing planted in the fixtures. If ANY of these strings
  # reaches the wire, the parser/whitelist leaked content.
  @content_markers [
    "SUPERSECRETPROMPT",
    "SUPERSECRET_FILE",
    "SUPERSECRET_PATH",
    "Bash",
    "Edit",
    "Read",
    "/etc/",
    "/home/",
    "command",
    "file_path"
  ]

  @allowed_keys Enum.map(Counters.wire_fields() ++ Counters.identity_fields(), &Atom.to_string/1)

  test "to_wire/2 emits exactly the counter whitelist plus identity — nothing else" do
    %{counters: counters} =
      TranscriptParser.parse(File.read!(Path.join(@fixtures, "session_a.jsonl")))

    wire =
      Counters.to_wire(counters, %{
        session_uuid: "sess-aaaa-1111",
        session_name: "kazi-alpha",
        machine: "test-host"
      })

    keys = wire |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    assert keys == Enum.sort(@allowed_keys)
  end

  test "the shipped bus fact carries no transcript content" do
    # Capture the exact text the collector would post on the bus.
    parent = self()

    state_dir =
      Path.join(System.tmp_dir!(), "kazi-wire-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(state_dir) end)

    SessionCollector.collect(
      dir: @fixtures,
      state_dir: state_dir,
      machine: "test-host",
      poster: fn "fact", text, opts -> send(parent, {:fact, text, opts}) end,
      # Do not touch the read-model in this pure wire-shape assertion.
      write: fn _wire -> :ok end
    )

    facts = collect_facts([])
    assert facts != []

    for {text, opts} <- facts do
      # The fact is valid JSON whose keys are only the whitelist.
      assert {:ok, decoded} = Jason.decode(text)
      assert Enum.sort(Map.keys(decoded)) == Enum.sort(@allowed_keys)

      # The topic is session-scoped, not content.
      assert opts[:topic] =~ ~r/^session:/

      # No content marker appears anywhere in the encoded payload.
      for marker <- @content_markers do
        refute String.contains?(text, marker),
               "content marker #{inspect(marker)} leaked into the bus fact: #{text}"
      end
    end
  end

  defp collect_facts(acc) do
    receive do
      {:fact, text, opts} -> collect_facts([{text, opts} | acc])
    after
      0 -> acc
    end
  end
end
