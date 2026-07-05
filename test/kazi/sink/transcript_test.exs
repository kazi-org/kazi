defmodule Kazi.Sink.TranscriptTest do
  @moduledoc """
  Tier 1 — `Kazi.Sink.Transcript` in isolation (T46.3, ADR-0057 decision 3):
  event extraction (structured JSON lines vs plain text), redaction, ordering,
  and the size-cap/truncation-marker behaviour. The end-to-end tee-through-
  dispatch proof lives in `test/kazi/integration/transcript_sink_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Kazi.Sink.Transcript

  setup do
    dir =
      Path.join(System.tmp_dir!(), "kazi-transcript-sink-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, path: Path.join(dir, "transcript.jsonl")}
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)
  defp decoded_lines(path), do: path |> lines() |> Enum.map(&Jason.decode!/1)

  test "nil path is a no-op", %{path: path} do
    assert :ok = Transcript.tee(nil, ~s({"type":"text","text":"hi"}), [])
    refute File.exists?(path)
  end

  test "empty output is a no-op", %{path: path} do
    assert :ok = Transcript.tee(path, "", [])
    refute File.exists?(path)
  end

  test "structured JSON lines and plain text lines land in order", %{path: path} do
    raw = """
    {"type":"tool_use","name":"Edit","input":{"path":"lib/foo.ex"}}
    plain stdout chunk
    {"type":"text","text":"done"}
    """

    assert :ok = Transcript.tee(path, raw, [])

    assert [tool_event, text_event, done_event] = decoded_lines(path)

    assert tool_event == %{
             "type" => "tool_use",
             "name" => "Edit",
             "input" => %{"path" => "lib/foo.ex"}
           }

    assert text_event == %{"type" => "text", "text" => "plain stdout chunk"}
    assert done_event == %{"type" => "text", "text" => "done"}
  end

  test "a seeded secret is redacted on disk, in both structured and plain lines", %{path: path} do
    raw = """
    {"type":"text","text":"export AWS_KEY=AKIAIOSFODNN7EXAMPLE"}
    DATABASE_URL=postgres://app:s3cr3t@db:5432/prod
    """

    Transcript.tee(path, raw, [])

    content = File.read!(path)
    refute content =~ "AKIAIOSFODNN7EXAMPLE"
    refute content =~ "s3cr3t"
    assert content =~ "[REDACTED]"
  end

  test "appends across multiple tee calls, preserving order", %{path: path} do
    Transcript.tee(path, ~s({"type":"text","text":"first"}), [])
    Transcript.tee(path, ~s({"type":"text","text":"second"}), [])

    assert [%{"text" => "first"}, %{"text" => "second"}] = decoded_lines(path)
  end

  test "exceeding the size cap drops further events and writes ONE truncation marker", %{
    path: path
  } do
    raw = Enum.map_join(1..50, "\n", fn i -> ~s({"type":"text","text":"line #{i}"}) end)

    Transcript.tee(path, raw, cap_bytes: 100)

    events = decoded_lines(path)
    assert List.last(events) == %{"type" => "truncated", "reason" => "size_cap_exceeded"}
    assert Enum.count(events, &(&1["type"] == "truncated")) == 1
    assert length(events) < 50
  end

  test "a sink already truncated stays truncated across a later tee call (no duplicate marker)",
       %{
         path: path
       } do
    Transcript.tee(path, ~s({"type":"text","text":"#{String.duplicate("x", 200)}"}),
      cap_bytes: 50
    )

    assert Enum.count(decoded_lines(path), &(&1["type"] == "truncated")) == 1

    Transcript.tee(path, ~s({"type":"text","text":"more after truncation"}), cap_bytes: 50)

    events = decoded_lines(path)
    assert Enum.count(events, &(&1["type"] == "truncated")) == 1
    refute Enum.any?(events, &(&1["text"] == "more after truncation"))
  end
end
