defmodule Kazi.Authoring.ClarifyGrepLintTest do
  @moduledoc """
  Regression pin for a "naked grep" bug in `Kazi.Authoring.Clarify`'s
  `http-status` gap detector: its endpoint sniff used a bare `\\/[a-z]` pattern,
  which matches ANY slash-separated prose idiom ("either/or", "cost/benefit",
  "and/or", "his/her", "read/write") -- not just an HTTP path -- so an idea with
  none of those in it still spuriously asked "what status must the endpoint
  return?". The fix requires the slash to actually start a path token (not be
  embedded mid-word); this test pins both directions so the pattern cannot
  regress back to a naked slash-letter grep.
  """
  use ExUnit.Case, async: true

  alias Kazi.Authoring.Clarify

  defp asks_http_status?(idea) do
    idea |> Clarify.gaps() |> Enum.any?(&(&1.id == "http-status"))
  end

  describe "http-status gap detector -- no false positives on prose slash idioms" do
    test "slash idioms embedded in a word do not trigger the endpoint question" do
      refute asks_http_status?("add support for either/or auth flows")
      refute asks_http_status?("improve the cost/benefit analysis tool")
      refute asks_http_status?("support and/or filtering in search")
      refute asks_http_status?("track his/her pronoun preferences")
      refute asks_http_status?("handle read/write locks correctly")
    end

    test "an idea with no endpoint signal at all asks no http-status question" do
      refute asks_http_status?("add a widgets feature")
    end
  end

  describe "http-status gap detector -- still catches real endpoints" do
    test "a leading-slash path token triggers the endpoint question" do
      assert asks_http_status?("expose a /healthz endpoint")
      assert asks_http_status?("call the api at /v1/widgets")
    end

    test "a GET/POST verb followed by a path triggers the endpoint question" do
      assert asks_http_status?("GET /users returns a list")
    end

    test "the http/api/route/endpoint keywords still trigger it" do
      assert asks_http_status?("add an http endpoint for search")
      assert asks_http_status?("expose a new api")
      assert asks_http_status?("add a route for widgets")
    end
  end
end
