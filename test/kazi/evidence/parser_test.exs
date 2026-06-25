defmodule Kazi.Evidence.ParserTest do
  @moduledoc """
  Tier 1/2 — the shared SARIF + JUnit-XML parsers (ADR-0041 decision 3, T32.2).

  Beyond the inline doctests, this writes REAL `.sarif` / `.xml` fixture files to
  a per-test temp dir and parses them off disk — the path a provider takes when it
  redirects a checker's report to a file and maps it onto the evidence envelope.
  Fixtures are generic (no internal hostnames/paths).
  """
  use ExUnit.Case, async: true
  doctest Kazi.Evidence.Parser

  alias Kazi.Evidence
  alias Kazi.Evidence.Parser

  @sarif """
  {
    "version": "2.1.0",
    "runs": [
      {
        "tool": { "driver": { "name": "demo-linter" } },
        "results": [
          {
            "ruleId": "no-unused-var",
            "level": "warning",
            "message": { "text": "unused variable x" },
            "locations": [
              {
                "physicalLocation": {
                  "artifactLocation": { "uri": "lib/example.ex" },
                  "region": { "startLine": 14, "startColumn": 5 }
                }
              }
            ]
          },
          {
            "ruleId": "no-shadow",
            "level": "error",
            "message": { "text": "shadowed binding y" },
            "locations": [
              {
                "physicalLocation": {
                  "artifactLocation": { "uri": "lib/other.ex" },
                  "region": { "startLine": 3 }
                }
              }
            ]
          }
        ]
      }
    ]
  }
  """

  @junit """
  <?xml version="1.0" encoding="UTF-8"?>
  <testsuites>
    <testsuite name="ExampleTest" tests="3" failures="1" errors="1">
      <testcase classname="ExampleTest" name="passes" time="0.01"/>
      <testcase classname="ExampleTest" name="adds" file="test/example_test.exs" line="22" time="0.02">
        <failure message="Assertion failed: expected 3, got 4" type="ExUnit.AssertionError">stacktrace here</failure>
      </testcase>
      <testcase classname="ExampleTest" name="boots" file="test/example_test.exs" line="40" time="0.0">
        <error type="RuntimeError">boom</error>
      </testcase>
    </testsuite>
  </testsuites>
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "sarif/1" do
    test "maps each result onto an evidence item with rule/level/file/line/col" do
      assert {:ok, [warn, err]} = Parser.sarif(@sarif)

      assert warn == %Evidence{
               file: "lib/example.ex",
               line: 14,
               col: 5,
               rule: "no-unused-var",
               level: :warning,
               message: "unused variable x"
             }

      assert err.rule == "no-shadow"
      assert err.level == :error
      assert err.file == "lib/other.ex"
      assert err.line == 3
      # No startColumn in the fixture → col stays nil.
      assert err.col == nil
    end

    test "parses a real .sarif file written to a temp dir", %{dir: dir} do
      path = Path.join(dir, "report.sarif")
      File.write!(path, @sarif)

      assert {:ok, items} = Parser.sarif(File.read!(path))
      assert length(items) == 2
      assert Enum.map(items, & &1.rule) == ["no-unused-var", "no-shadow"]
    end

    test "an empty results array yields an empty list" do
      assert {:ok, []} = Parser.sarif(~s({"runs": [{"results": []}]}))
    end

    test "invalid JSON is a clean error, not a raise" do
      assert {:error, {:invalid_json, _}} = Parser.sarif("not json {")
    end

    test "valid JSON that is not SARIF is a clean error" do
      assert {:error, :not_sarif} = Parser.sarif(~s({"hello": "world"}))
    end
  end

  describe "junit/1" do
    test "emits one item per failing/erroring testcase and skips passing ones" do
      assert {:ok, items} = Parser.junit(@junit)

      # 1 failure + 1 error; the passing testcase produces no evidence.
      assert length(items) == 2

      [failure, error] = items

      assert failure.file == "test/example_test.exs"
      assert failure.line == 22
      assert failure.rule == "ExampleTest.adds"
      assert failure.level == :error
      assert failure.message == "Assertion failed: expected 3, got 4"

      assert error.rule == "ExampleTest.boots"
      assert error.level == :error
      # No message attribute → falls back to the element's text body.
      assert error.message == "boom"
    end

    test "parses a real .xml file written to a temp dir", %{dir: dir} do
      path = Path.join(dir, "junit.xml")
      File.write!(path, @junit)

      assert {:ok, items} = Parser.junit(File.read!(path))
      assert Enum.map(items, & &1.rule) == ["ExampleTest.adds", "ExampleTest.boots"]
    end

    test "an all-passing suite yields an empty list" do
      xml = ~s(<testsuite><testcase classname="M" name="ok"/></testsuite>)
      assert {:ok, []} = Parser.junit(xml)
    end

    test "malformed XML is a clean error, not a raise" do
      assert {:error, {:invalid_xml, _}} = Parser.junit("<testsuite><testcase>")
    end
  end
end
