defmodule Kazi.Evidence do
  @moduledoc """
  The shared structured-evidence envelope and its parsers (ADR-0041).

  A checker that returns 5KB of raw log is poor fix-context; one that returns the
  failing finding's `file:line`, rule, and expected-vs-got lets an automated fixer
  act directly. ADR-0041 standardizes on the LSP `Diagnostic` shape and provides
  ONE parser providers map their native output onto, so the mapping is built once,
  not per provider (shared with the `custom_script` provider, ADR-0040):

    * `from_sarif/1` — SARIF (the static-analysis interchange format: golangci-lint,
      Semgrep, tsc-via-SARIF, …) → evidence items.
    * `from_junit/1` — JUnit XML (the test-result interchange format) → evidence
      items, one per failing / errored / skipped test case.

  An **evidence item** (`item/1`) carries, all optional:

      %{file, line, col, rule, level, message, expected, got}

  Both parsers are **total**: malformed or unrecognized input yields `[]` (no
  structured items), and the caller keeps a truncated slice of raw stdout as the
  fallback (`truncate/2`) — never a crash in the observe path.
  """

  require Record

  # xmerl record shapes (OTP stdlib) for the JUnit-XML parser. Extracted as
  # private records so we read attributes/children without depending on xmerl's
  # tuple layout.
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

  @typedoc "An LSP-`Diagnostic`-shaped evidence item (ADR-0041)."
  @type item :: Kazi.PredicateResult.evidence_item()

  # The canonical key set, in a stable order. `item/1` fills every key (defaulting
  # to nil) so downstream code can pattern-match a known shape.
  @keys [:file, :line, :col, :rule, :level, :message, :expected, :got]

  @doc """
  Normalizes an arbitrary attribute map into a canonical evidence `t:item/0`:
  every one of `#{inspect(@keys)}` is present (absent keys default to `nil`), and
  any extra keys are dropped. Accepts atom- or string-keyed input, so a parser or
  a provider can hand in whatever it has.

  ## Examples

      iex> Kazi.Evidence.item(%{file: "a.ex", line: 3, message: "boom"})
      %{file: "a.ex", line: 3, col: nil, rule: nil, level: nil, message: "boom", expected: nil, got: nil}
  """
  @spec item(map()) :: item()
  def item(attrs) when is_map(attrs) do
    Map.new(@keys, fn key -> {key, fetch_attr(attrs, key)} end)
  end

  # Look a key up under its atom or string form (parsers build atom-keyed maps;
  # callers may pass either).
  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  @doc """
  Parses SARIF (a decoded map, or a JSON string) into a list of evidence items —
  one per `runs[].results[]` entry, in document order.

  Each result's `ruleId` → `rule`, `level` → `level`, `message.text` → `message`,
  and the first `locations[].physicalLocation` → `file` (`artifactLocation.uri`)
  and `line`/`col` (`region.startLine`/`startColumn`). Anything absent is `nil`.

  Total: a non-SARIF map, an undecodable string, or a shape with no results yields
  `[]`.
  """
  @spec from_sarif(map() | binary()) :: [item()]
  def from_sarif(sarif) when is_binary(sarif) do
    case Jason.decode(sarif) do
      {:ok, decoded} -> from_sarif(decoded)
      {:error, _} -> []
    end
  end

  def from_sarif(%{"runs" => runs}) when is_list(runs) do
    Enum.flat_map(runs, fn run -> run |> sarif_results() |> Enum.map(&sarif_item/1) end)
  end

  def from_sarif(_other), do: []

  defp sarif_results(%{"results" => results}) when is_list(results), do: results
  defp sarif_results(_run), do: []

  defp sarif_item(%{} = result) do
    {file, line, col} = sarif_location(result)

    item(%{
      file: file,
      line: line,
      col: col,
      rule: result["ruleId"],
      level: result["level"],
      message: get_in(result, ["message", "text"])
    })
  end

  # The first physical location, if any: file uri + start line/column.
  defp sarif_location(%{"locations" => [%{"physicalLocation" => phys} | _]}) do
    file = get_in(phys, ["artifactLocation", "uri"])
    line = get_in(phys, ["region", "startLine"])
    col = get_in(phys, ["region", "startColumn"])
    {file, line, col}
  end

  defp sarif_location(_result), do: {nil, nil, nil}

  @doc """
  Parses a JUnit-XML string into a list of evidence items — one per test case that
  carries a `<failure>`, `<error>`, or `<skipped>` child, in document order. A
  passing test case contributes no item (it is not a finding).

  Each item's `file`/`line` come from the `<testcase>` attributes (when present),
  `rule` from the test's `classname`+`name` (its identity), `level` from the child
  tag (`failure`/`error`/`skipped`), and `message` from the child's `message`
  attribute (falling back to its text body).

  Total: malformed XML, or XML with no failing cases, yields `[]`.
  """
  @spec from_junit(binary()) :: [item()]
  def from_junit(xml) when is_binary(xml) do
    case scan_xml(xml) do
      {:ok, root} ->
        root
        |> elements_named("testcase")
        |> Enum.flat_map(&junit_case_items/1)

      :error ->
        []
    end
  end

  # Parse the XML string, isolating xmerl's exits (it `exit`s on malformed input)
  # so a bad fixture is `[]`, never a crashed observe.
  defp scan_xml(xml) do
    {root, _rest} = :xmerl_scan.string(String.to_charlist(xml), quiet: true)
    {:ok, root}
  catch
    :exit, _ -> :error
    _, _ -> :error
  end

  # The findings for one <testcase>: one item per failure/error/skipped child.
  defp junit_case_items(testcase) do
    file = attr(testcase, "file")
    line = testcase |> attr("line") |> to_integer()
    rule = junit_rule(testcase)

    for child <- child_elements(testcase),
        element_name(child) in ["failure", "error", "skipped"] do
      item(%{
        file: file,
        line: line,
        rule: rule,
        level: element_name(child),
        message: attr(child, "message") || text_of(child)
      })
    end
  end

  # The test's identity: "classname.name", "name", or nil.
  defp junit_rule(testcase) do
    name = attr(testcase, "name")
    classname = attr(testcase, "classname")

    case {classname, name} do
      {nil, nil} -> nil
      {nil, name} -> name
      {classname, nil} -> classname
      {classname, name} -> "#{classname}.#{name}"
    end
  end

  @doc """
  Truncates raw stdout to at most `max` bytes for the fallback evidence slice,
  appending an elision marker when it was cut. The structured items are the
  primary fix-context (ADR-0041); this keeps a bounded tail of raw output for the
  cases a parser cannot localize.
  """
  @spec truncate(binary(), non_neg_integer()) :: binary()
  def truncate(output, max \\ 4_000) when is_binary(output) and is_integer(max) and max >= 0 do
    if byte_size(output) <= max do
      output
    else
      binary_part(output, 0, max) <> "\n…[truncated]"
    end
  end

  # --- xmerl navigation helpers ----------------------------------------------

  # All descendant elements with the given tag name, depth-first in document order.
  defp elements_named(element, name) when is_binary(name) do
    target = String.to_charlist(name)

    self =
      if xmlElement(element, :name) == List.to_atom(target), do: [element], else: []

    self ++ Enum.flat_map(child_elements(element), &elements_named(&1, name))
  end

  defp child_elements(xmlElement(content: content)) do
    Enum.filter(content, fn node -> is_tuple(node) and elem(node, 0) == :xmlElement end)
  end

  defp element_name(xmlElement(name: name)), do: Atom.to_string(name)

  # An element's attribute value as a string, or nil if absent.
  defp attr(xmlElement(attributes: attributes), name) do
    target = List.to_atom(String.to_charlist(name))

    Enum.find_value(attributes, fn
      xmlAttribute(name: ^target, value: value) -> List.to_string(value)
      _ -> nil
    end)
  end

  # The concatenated text content of an element (its xmlText children), trimmed;
  # nil when empty.
  defp text_of(xmlElement(content: content)) do
    text =
      content
      |> Enum.map(fn
        xmlText(value: value) -> List.to_string(value)
        _ -> ""
      end)
      |> Enum.join()
      |> String.trim()

    if text == "", do: nil, else: text
  end

  defp to_integer(nil), do: nil

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end
end
