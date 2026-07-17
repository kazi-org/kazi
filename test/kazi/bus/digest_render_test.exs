defmodule Kazi.Bus.DigestRenderTest do
  @moduledoc """
  T55.1 (ADR-0072 d1/d2/d6): `Kazi.Bus.Digest.render/1` -- the bounded,
  machine-readable digest every `--json` / MCP bus read returns by default.

  Pure-function tests, untagged (no NATS needed): the <=40-line bound with
  exact counts, the oversize stub rule (applies to ALL kinds including
  directed/interrupt), verbatim-only-for-directed-or-interrupt, ids carried
  on every line, and the overflow line when even the line set would exceed
  the bound. The TTY path (`summarize/1`) is pinned unchanged by
  `Kazi.Bus.MvpTest`.
  """
  use ExUnit.Case, async: true

  alias Kazi.Bus.Digest

  defp msg(id, kind, topic, text, sev \\ "info") do
    %{
      id: id,
      kind: kind,
      topic: topic,
      text: text,
      sev: sev,
      session: "s-#{id}",
      machine: "m1",
      ts: "2026-07-16T00:00:0#{rem(id, 10)}Z",
      scope: "machine"
    }
  end

  describe "render/1 -- the bound (ADR-0072 d6)" do
    test "empty input renders an empty digest" do
      assert Digest.render([]) == %{"total" => 0, "lines" => []}
    end

    test "200 messages across 3 kinds collapse to <=40 lines with exact counts" do
      messages =
        for id <- 1..200 do
          kind = Enum.at(["fact", "note", "announce"], rem(id, 3))
          msg(id, kind, "ci", "message #{id}")
        end

      %{"total" => 200, "lines" => lines} = Digest.render(messages)

      assert length(lines) <= Digest.max_lines()
      assert Enum.all?(lines, &(&1["type"] == "count"))
      # Exact counts preserved: the count lines sum to the full backlog.
      assert Enum.sum(Enum.map(lines, & &1["count"])) == 200
    end

    test "count lines carry the kind/topic group and a dereferenceable id range" do
      messages = [
        msg(11, "note", "ci", "a"),
        msg(12, "note", "ci", "b"),
        msg(13, "fact", nil, "c")
      ]

      %{"lines" => lines} = Digest.render(messages)

      assert %{"count" => 2, "first_id" => 11, "last_id" => 12} =
               Enum.find(lines, &(&1["kind"] == "note" and &1["topic"] == "ci"))

      assert %{"count" => 1, "topic" => nil} = Enum.find(lines, &(&1["kind"] == "fact"))
    end

    test "a pathological backlog (100 directed messages) still renders <=40 lines, with an exact overflow" do
      messages = for id <- 1..100, do: msg(id, "msg", "me", "direct #{id}")

      %{"total" => 100, "lines" => lines} = Digest.render(messages)

      assert length(lines) == Digest.max_lines()

      overflow = List.last(lines)
      assert overflow["type"] == "overflow"
      # 39 verbatim lines kept; the overflow line accounts for the other 61 exactly.
      assert overflow["count"] == 100 - (Digest.max_lines() - 1)
      assert overflow["first_id"] == Digest.max_lines()
      assert overflow["last_id"] == 100
    end
  end

  describe "render/1 -- verbatim is reserved for directed / interrupt (ADR-0072 d7)" do
    test "directed (kind msg) and sev interrupt render verbatim with their ids" do
      messages = [
        msg(1, "msg", "me", "ping me"),
        msg(2, "note", "ci", "build red", "interrupt"),
        msg(3, "note", "ci", "routine")
      ]

      %{"lines" => lines} = Digest.render(messages)

      assert %{"type" => "verbatim", "id" => 1, "text" => "ping me"} =
               Enum.find(lines, &(&1["kind"] == "msg"))

      assert %{"type" => "verbatim", "id" => 2, "text" => "build red", "sev" => "interrupt"} =
               Enum.find(lines, &(&1["sev"] == "interrupt"))

      assert %{"type" => "count", "count" => 1} = Enum.find(lines, &(&1["type"] == "count"))
    end
  end

  describe "render/1 -- the oversize stub rule (ADR-0072 d2)" do
    test "a body over the render threshold NEVER renders verbatim -- even directed/interrupt" do
      big = String.duplicate("x", Digest.render_threshold_bytes() + 1)

      messages = [
        msg(7, "msg", "me", big),
        msg(8, "note", "ci", big, "interrupt"),
        msg(9, "fact", "docs", big)
      ]

      %{"lines" => lines} = Digest.render(messages)

      stubs = Enum.filter(lines, &(&1["type"] == "stub"))
      assert length(stubs) == 3

      for stub <- stubs do
        refute Map.has_key?(stub, "text")
        assert stub["bytes"] == byte_size(big)
        assert is_integer(stub["id"])
        assert is_binary(stub["kind"])
        assert is_binary(stub["session"])
        assert is_binary(stub["machine"])
      end

      refute Jason.encode!(lines) =~ big
    end

    test "a body exactly AT the threshold still renders verbatim when directed" do
      at_cap = String.duplicate("y", Digest.render_threshold_bytes())

      %{"lines" => [line]} = Digest.render([msg(4, "msg", "me", at_cap)])
      assert line["type"] == "verbatim"
      assert line["text"] == at_cap
    end

    test "the threshold is the documented ~1 KiB constant" do
      assert Digest.render_threshold_bytes() == 1024
      assert Digest.max_lines() == 40
    end
  end

  describe "render/1 -- line order" do
    test "verbatim/stub lines come first in stream order, then count lines by frequency" do
      big = String.duplicate("z", Digest.render_threshold_bytes() + 1)

      messages = [
        msg(1, "note", "ci", "one"),
        msg(2, "msg", "me", "direct"),
        msg(3, "note", "docs", big),
        msg(4, "note", "ci", "two")
      ]

      %{"lines" => lines} = Digest.render(messages)

      assert Enum.map(lines, & &1["type"]) == ["verbatim", "stub", "count"]
      assert Enum.map(lines, & &1["id"]) == [2, 3, nil]
    end
  end

  describe "get_view/2 -- the bus get preview bound (ADR-0072 d3, T55.6)" do
    defp fetched(text),
      do: %{
        "id" => 7,
        "kind" => "note",
        "topic" => "doc",
        "bytes" => byte_size(text),
        "text" => text
      }

    test "a body within the threshold is returned whole, truncated false, even without full" do
      small = String.duplicate("a", 100)
      view = Digest.get_view(fetched(small), false)

      assert view["text"] == small
      assert view["truncated"] == false
    end

    test "a body over the threshold is cut to a preview with truncated true by default" do
      big = String.duplicate("b", 5_000)
      view = Digest.get_view(fetched(big), false)

      assert view["truncated"] == true
      assert byte_size(view["text"]) <= Digest.render_threshold_bytes()
      assert String.starts_with?(big, view["text"])
      # `bytes` still reports the FULL size, so a caller knows what it did not get.
      assert view["bytes"] == byte_size(big)
    end

    test "full: true returns the whole body unabridged, truncated false" do
      big = String.duplicate("c", 5_000)
      view = Digest.get_view(fetched(big), true)

      assert view["text"] == big
      assert view["truncated"] == false
    end

    test "a preview never splits a multi-byte codepoint into invalid UTF-8" do
      # A 2-byte codepoint straddling the 1024-byte boundary would be cut mid-char
      # by a naive byte slice; the preview must stay valid UTF-8 (or JSON encoding
      # of the view would fail).
      big = String.duplicate("é", 1_000)
      view = Digest.get_view(fetched(big), false)

      assert view["truncated"] == true
      assert String.valid?(view["text"])
      assert {:ok, _json} = Jason.encode(view)
    end
  end
end
