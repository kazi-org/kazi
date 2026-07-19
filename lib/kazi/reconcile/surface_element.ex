defmodule Kazi.Reconcile.SurfaceElement do
  @moduledoc """
  One element of a project's **public surface** (ADR-0021, decision 3): a thing
  the outside world can reach — a public function, a Mix task, a CLI command, an
  HTTP route. Each carries a coarse `:kind`, a stable `:identifier`, and the
  `:source` location (file + line) it was discovered at.

  This is the unit the surface-scanner (`Kazi.Reconcile.SurfaceScanner`) emits and
  the surface-coverage meta-predicate (T13.5) will own against the intended set.
  An element is deliberately *flat and structural*: it records WHERE a public
  entry point is, not what it does — enough to ask "is this owned by >=1 intended
  predicate?" and no more.

  Identifiers are normalized per kind so the same surface element scanned twice is
  byte-identical (determinism, ADR-0010 / ADR-0021):

    * `:exported_function` — `"Module.Name.fun/arity"` (e.g. `"Calc.add/2"`).
    * `:mix_task` — the task's invocation name (e.g. `"mix surface.scan"`).
    * `:cli_command` — the command token (e.g. `"kazi run"`); reserved for a
      later language/dispatch pass.
    * `:http_route` — `"VERB /path"`; reserved for the web pass.
  """

  @typedoc """
    * `:kind` — coarse surface kind.
    * `:identifier` — normalized, kind-specific identity string.
    * `:path` — workspace-relative path of the defining file.
    * `:line` — 1-based line of the definition (`nil` when not resolved).
  """
  @type kind :: :exported_function | :mix_task | :cli_command | :http_route

  @type t :: %__MODULE__{
          kind: kind(),
          identifier: String.t(),
          path: String.t(),
          line: pos_integer() | nil
        }

  @enforce_keys [:kind, :identifier, :path]
  defstruct kind: nil, identifier: nil, path: nil, line: nil

  @doc """
  Builds a surface element. `:line` is optional and defaults to `nil` when the
  definition's line is not resolvable.

  ## Examples

      iex> e = Kazi.Reconcile.SurfaceElement.new(:exported_function, "Calc.add/2", "lib/calc.ex", 3)
      iex> {e.kind, e.identifier, e.line}
      {:exported_function, "Calc.add/2", 3}
  """
  @spec new(kind(), String.t(), String.t(), pos_integer() | nil) :: t()
  def new(kind, identifier, path, line \\ nil)
      when is_atom(kind) and is_binary(identifier) and is_binary(path) and
             (is_nil(line) or (is_integer(line) and line > 0)) do
    %__MODULE__{kind: kind, identifier: identifier, path: path, line: line}
  end

  @doc """
  A total ordering key making a scan's output deterministic regardless of
  filesystem walk order: sort by `{kind, identifier, path, line}`.
  """
  @spec sort_key(t()) :: {atom(), String.t(), String.t(), integer()}
  def sort_key(%__MODULE__{kind: kind, identifier: id, path: path, line: line}) do
    {kind, id, path, line || 0}
  end
end
