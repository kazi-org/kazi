defmodule Kazi.Bus.ClaimsTest do
  @moduledoc """
  T55.8 (ADR-0073 point 2): the claim-ref PARSING logic in isolation -- owner,
  host, and age extracted from the real claim commit subject, without any git or
  daemon involvement.
  """
  use ExUnit.Case, async: true

  alias Kazi.Bus.Claims

  describe "parse_subject/1" do
    test "splits owner and host from a claim subject" do
      subject = "claim T55.8 by dev@sire.run@build-box 2026-07-16T09:00:00Z"
      assert Claims.parse_subject(subject) == {"dev@sire.run", "build-box"}
    end

    test "host is the segment after the LAST @ -- owner emails keep their own @" do
      subject = "claim R-doc by a.b.c@example.org@laptop 2026-07-16T09:00:00Z"
      assert {"a.b.c@example.org", "laptop"} = Claims.parse_subject(subject)
    end

    test "an identity with no @ leaves host nil" do
      subject = "claim T1.2 by alice host-1 2026-07-16T09:00:00Z"
      # `alice host-1` -- with no @, the whole who-token is the owner.
      assert {"alice host-1", nil} = Claims.parse_subject(subject)
    end

    test "a non-claim subject yields no owner or host" do
      assert Claims.parse_subject("some unrelated commit message") == {nil, nil}
    end
  end

  describe "parse_line/2" do
    test "projects task, owner, host, and age from a for-each-ref line" do
      now = 1_000_000
      claimed_at = now - 125
      line = "T55.8\t#{claimed_at}\tclaim T55.8 by dev@sire.run@box 2026-07-16T09:00:00Z"

      assert Claims.parse_line(line, now) == %{
               "task" => "T55.8",
               "owner" => "dev@sire.run",
               "host" => "box",
               "age_s" => 125
             }
    end

    test "a claim in the future clamps age to zero, never negative" do
      now = 1_000
      line = "T9.9\t#{now + 500}\tclaim T9.9 by dev@box2 2026-07-16T09:00:00Z"
      assert %{"age_s" => 0} = Claims.parse_line(line, now)
    end

    test "a malformed line is dropped (nil), never a half-claim" do
      assert Claims.parse_line("not-tab-separated", 1) == nil
      assert Claims.parse_line("\t123\tclaim x by y@z t", 1) == nil
    end
  end
end
