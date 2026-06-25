defmodule Kazi.Evidence.Parser do
  @moduledoc """
  Maps the two checker-output lingua francas — SARIF (static-analysis findings,
  JSON) and JUnit XML (test results) — onto the shared `Kazi.Evidence` envelope
  (ADR-0041 decision 3).

  A provider that already emits SARIF or JUnit (most linters, most test runners)
  gets structured, `file:line`-localized evidence for free by piping its output
  through here, instead of handing a fixer raw stdout. Both parsers are TOTAL:
  malformed or unrecognized input yields `{:error, reason}` rather than raising,
  so a provider can fall back to truncated raw stdout (ADR-0041) without a crash.

  * `sarif/1` reads a SARIF log (the OASIS static-analysis result format) and
    returns one `Kazi.Evidence` per `runs[].results[]`, taking the rule id,
    level, message, and first physical location (`uri` + `startLine`/`startColumn`).
  * `junit/1` reads a JUnit XML report and returns one `Kazi.Evidence` per
    `<testcase>` carrying a `<failure>` or `<error>` child — passing testcases
    produce no item (only the work-list is evidence). Uses OTP's `:xmerl` (no new
    dependency).
  """

  alias Kazi.Evidence

  @doc """
  Parses a SARIF (JSON) string into a list of `Kazi.Evidence` items, one per
  result across every run. Returns `{:ok, [Evidence.t()]}`, or `{:error, reason}`
  when the input is not valid JSON or not a SARIF log (no `runs` array).

  ## Examples

      iex> sarif = ~s({"runs":[{"results":[{"ruleId":"no-x","level":"error","message":{"text":"boom"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.ex"},"region":{"startLine":7}}}]}]}]})
      iex> {:ok, [item]} = Kazi.Evidence.Parser.sarif(sarif)
      iex> {item.rule, item.level, item.file, item.line, item.message}
      {"no-x", :error, "a.ex", 7, "boom"}
  """
  @spec sarif(String.t()) :: {:ok, [Evidence.t()]} | {:error, term()}
  def sarif(json) when is_binary(json) do
    with {:ok, %{"runs" => runs}} when is_list(runs) <- decode_sarif(json) do
      items =
        for run <- runs,
            is_map(run),
            result <- Map.get(run, "results", []) || [],
            is_map(result) do
          sarif_result_to_item(result)
        end

      {:ok, items}
    end
  end

  @doc """
  Parses a JUnit XML report into a list of `Kazi.Evidence` items, one per failing
  or erroring `<testcase>`. Passing testcases yield no item. Returns
  `{:ok, [Evidence.t()]}`, or `{:error, reason}` when the XML cannot be parsed.

  ## Examples

      iex> xml = ~s(<testsuite><testcase classname="M" name="t" file="a.ex" line="9"><failure message="expected 1, got 2">detail</failure></testcase></testsuite>)
      iex> {:ok, [item]} = Kazi.Evidence.Parser.junit(xml)
      iex> {item.file, item.line, item.rule, item.level, item.message}
      {"a.ex", 9, "M.t", :error, "expected 1, got 2"}
  """
  @spec junit(String.t()) :: {:ok, [Evidence.t()]} | {:error, term()}
  def junit(xml) when is_binary(xml) do
    case scan_xml(xml) do
      {:ok, doc} ->
        items =
          doc
          |> xpath(~c"//testcase")
          |> Enum.flat_map(&junit_testcase_to_items/1)

        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- SARIF --------------------------------------------------------------------

  defp decode_sarif(json) do
    case Jason.decode(json) do
      {:ok, %{"runs" => _} = log} -> {:ok, log}
      {:ok, _other} -> {:error, :not_sarif}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp sarif_result_to_item(result) do
    {file, line, col} = sarif_location(result)

    Evidence.new(
      file: file,
      line: line,
      col: col,
      rule: result["ruleId"],
      level: sarif_level(result["level"]),
      message: sarif_message(result["message"])
    )
  end

  # SARIF's first physical location, if any: artifactLocation.uri +
  # region.startLine / region.startColumn.
  defp sarif_location(result) do
    with [loc | _] <- result["locations"] || [],
         %{"physicalLocation" => phys} when is_map(phys) <- loc do
      region = phys["region"] || %{}
      {get_in(phys, ["artifactLocation", "uri"]), region["startLine"], region["startColumn"]}
    else
      _ -> {nil, nil, nil}
    end
  end

  # SARIF result.message is `%{"text" => "..."}` (with an optional markdown form).
  defp sarif_message(%{"text" => text}) when is_binary(text), do: text
  defp sarif_message(text) when is_binary(text), do: text
  defp sarif_message(_), do: nil

  # SARIF levels: none / note / warning / error. Anything else (or absent) → nil.
  defp sarif_level("error"), do: :error
  defp sarif_level("warning"), do: :warning
  defp sarif_level("note"), do: :note
  defp sarif_level(_), do: nil

  # --- JUnit --------------------------------------------------------------------

  # A `<testcase>` is evidence only when it carries a `<failure>` or `<error>`
  # child — a passing case is not work. Multiple failures on one case each become
  # an item (rare but valid).
  defp junit_testcase_to_items(testcase) do
    rule = junit_rule(testcase)
    file = attr(testcase, ~c"file")
    line = attr_int(testcase, ~c"line")

    (xpath(testcase, ~c"failure") ++ xpath(testcase, ~c"error"))
    |> Enum.map(fn fault ->
      Evidence.new(
        file: file,
        line: line,
        rule: rule,
        level: :error,
        message: junit_message(fault)
      )
    end)
  end

  # The rule is the test's identity: "classname.name" when both are present, else
  # whichever exists.
  defp junit_rule(testcase) do
    classname = attr(testcase, ~c"classname")
    name = attr(testcase, ~c"name")

    case {classname, name} do
      {nil, nil} -> nil
      {nil, name} -> name
      {classname, nil} -> classname
      {classname, name} -> "#{classname}.#{name}"
    end
  end

  # The failure/error message: the `message` attribute when present, else the
  # element's trimmed text body.
  defp junit_message(fault) do
    case attr(fault, ~c"message") do
      nil -> blank_to_nil(text_of(fault))
      message -> message
    end
  end

  # --- xmerl plumbing -----------------------------------------------------------

  require Record

  # Minimal xmerl record shapes (from xmerl.hrl) — just the fields we read.
  Record.defrecordp(
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  defp scan_xml(xml) do
    # xmerl raises on malformed input and emits warnings to stderr; trap both so a
    # broken report degrades to {:error, _} rather than crashing the loop.
    {doc, _rest} = :xmerl_scan.string(String.to_charlist(xml), quiet: true)
    {:ok, doc}
  rescue
    error -> {:error, {:invalid_xml, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:invalid_xml, reason}}
  end

  defp xpath(node, path) do
    :xmerl_xpath.string(path, node)
  rescue
    _ -> []
  end

  # An element's `name` attribute as a String, or nil.
  defp attr(element, name) do
    case :xmerl_xpath.string(~c"./@" ++ name, element) do
      [xmlAttribute(value: value) | _] -> to_string(value)
      _ -> nil
    end
  end

  defp attr_int(element, name) do
    case attr(element, name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> nil
        end
    end
  end

  # The concatenated text content of an element, trimmed.
  defp text_of(element) do
    element
    |> xmlElement(:content)
    |> Enum.map(fn
      xmlText(value: value) -> to_string(value)
      _ -> ""
    end)
    |> Enum.join()
    |> String.trim()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
