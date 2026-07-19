defmodule Kazi.Context.Symbol do
  @moduledoc """
  One ranked symbol in an orientation pack (T4.2, ADR-0010): a named definition
  (function, module, type) with the file it lives in and the structural edges —
  its `callers` and `callees` — that make it worth orienting around.

  Edges come from `code-review-graph` when the target has a graph; the repo-map
  fallback leaves them empty (it sees definitions, not call edges — the
  intentional source-vs-structure hybrid of ADR-0010). All edge lists are stored
  sorted so a pack built from the same survey is byte-identical.
  """

  @typedoc """
    * `:name` — the symbol's name (e.g. `"build_prompt/2"`, `"Kazi.Context"`).
    * `:path` — workspace-relative path of the file defining it.
    * `:kind` — coarse kind (`:function`, `:module`, `:type`, `:other`).
    * `:callers` / `:callees` — names of one structural hop in/out, sorted; empty
      under the repo-map fallback.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          path: String.t(),
          kind: :function | :module | :type | :other,
          callers: [String.t()],
          callees: [String.t()]
        }

  @enforce_keys [:name, :path]
  defstruct name: nil, path: nil, kind: :other, callers: [], callees: []

  @doc """
  Builds a symbol, sorting `:callers` and `:callees` so equal inputs yield an
  equal struct (determinism, ADR-0010).

  ## Examples

      iex> s = Kazi.Context.Symbol.new("f/1", "lib/a.ex", callees: ["z", "a"])
      iex> {s.kind, s.callees}
      {:other, ["a", "z"]}
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(name, path, opts \\ []) when is_binary(name) and is_binary(path) do
    %__MODULE__{
      name: name,
      path: path,
      kind: Keyword.get(opts, :kind, :other),
      callers: opts |> Keyword.get(:callers, []) |> Enum.sort(),
      callees: opts |> Keyword.get(:callees, []) |> Enum.sort()
    }
  end
end
