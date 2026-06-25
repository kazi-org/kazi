defmodule Kazi.JSONPath do
  @moduledoc """
  A focused JSONPath subset over an already-decoded JSON document, plus the
  number coercion the predicate framework gates on (extracted from
  `Kazi.Providers.CustomScript` so the `:custom_script` verdict and the
  `:ratchet` metric share ONE implementation — ADR-0040 / ADR-0041).

  The supported grammar is deliberately small and documented: a leading `$`,
  `.key` object segments, and `[index]` array subscripts
  (e.g. `"$.runs[0].results"`, `"$.summary.failures"`). Anything outside it is an
  explicit `{:invalid_path, path}` error rather than a silent miss — a checker
  must never read a mistyped path as a pass.

  `to_number/1` coerces the extracted value to a number for comparison: a number
  is used verbatim; a LIST uses its length (so a path pointing at a findings
  array compares its COUNT); anything else is `{:not_a_number, value}`.
  """

  @typedoc "A parsed path segment: an object key or an array index."
  @type token :: {:key, String.t()} | {:index, non_neg_integer()}

  # One JSONPath segment: a `.key` or a `[index]`.
  @path_token_re ~r/\.([^.\[\]]+)|\[(\d+)\]/

  @doc """
  Extracts the value at `path` from the already-decoded `data`. Returns
  `{:ok, value}`, or a tagged error: `{:invalid_path, path}` (the path does not
  match the supported subset), `{:path_missing, key, path}`,
  `{:path_index_out_of_range, index, path}`, or `{:path_type_mismatch, token,
  path}`.

  ## Examples

      iex> Kazi.JSONPath.get(%{"a" => [%{"b" => 3}]}, "$.a[0].b")
      {:ok, 3}

      iex> Kazi.JSONPath.get(%{"a" => 1}, "$.missing")
      {:error, {:path_missing, "missing", "$.missing"}}

      iex> Kazi.JSONPath.get(%{"a" => 1}, "a")
      {:error, {:invalid_path, "a"}}
  """
  @spec get(term(), String.t()) :: {:ok, term()} | {:error, term()}
  def get(data, path) do
    with {:ok, tokens} <- parse(path) do
      fetch(data, tokens, path)
    end
  end

  @doc """
  Coerces an extracted value to a number for comparison. A number is verbatim; a
  list uses its length; anything else is `{:error, {:not_a_number, value}}`.

  ## Examples

      iex> Kazi.JSONPath.to_number(0.82)
      {:ok, 0.82}

      iex> Kazi.JSONPath.to_number([%{}, %{}, %{}])
      {:ok, 3}

      iex> Kazi.JSONPath.to_number("nope")
      {:error, {:not_a_number, "nope"}}
  """
  @spec to_number(term()) :: {:ok, number()} | {:error, {:not_a_number, term()}}
  def to_number(n) when is_number(n), do: {:ok, n}
  def to_number(list) when is_list(list), do: {:ok, length(list)}
  def to_number(other), do: {:error, {:not_a_number, other}}

  # =============================================================================
  # Parsing
  # =============================================================================

  defp parse("$" <> rest), do: tokenize(rest)
  defp parse(path), do: {:error, {:invalid_path, path}}

  defp tokenize(rest) do
    matches = Regex.scan(@path_token_re, rest)
    consumed = matches |> Enum.map(&hd/1) |> Enum.join()

    if consumed == rest do
      {:ok, Enum.map(matches, &token/1)}
    else
      {:error, {:invalid_path, "$" <> rest}}
    end
  end

  # Regex.scan yields the full match plus the two alternation groups; the one that
  # did not participate is the empty string.
  defp token([_full, key, ""]), do: {:key, key}
  defp token([_full, "", index]), do: {:index, String.to_integer(index)}
  defp token([_full, key]), do: {:key, key}

  defp fetch(value, [], _path), do: {:ok, value}

  defp fetch(map, [{:key, key} | rest], path) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch(value, rest, path)
      :error -> {:error, {:path_missing, key, path}}
    end
  end

  defp fetch(list, [{:index, index} | rest], path) when is_list(list) do
    case Enum.fetch(list, index) do
      {:ok, value} -> fetch(value, rest, path)
      :error -> {:error, {:path_index_out_of_range, index, path}}
    end
  end

  defp fetch(_value, [token | _rest], path), do: {:error, {:path_type_mismatch, token, path}}
end
