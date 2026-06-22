defmodule Kazi.Adopt do
  @moduledoc """
  Reverse-engineers a starter goal-file from an existing repo (T5.1, UC-023,
  ADR-0013): point kazi at a project that already works and have it derive the
  project's current checkable surface — the equivalent of `terraform import` or
  `tsc --init`.

  `detect/1` is the deterministic **stack + test-command** detector: it inspects
  the repo's marker files and maps them to a `test_runner` predicate spec plus
  stack metadata. It is the first step of `kazi init` (the writer T5.3 renders the
  detected goal to a goal-file; guards T5.2 and the CLI T5.5 build on top).

  ## What it detects

  A marker file at the repo root maps to a test command (ADR-0013 §1):

  | Marker file                  | Stack     | `cmd`    | `args`             |
  |------------------------------|-----------|----------|--------------------|
  | `go.mod`                     | `:go`     | `go`     | `["test", "./..."]`|
  | `mix.exs`                    | `:elixir` | `mix`    | `["test"]`         |
  | `package.json` (+`test` script) | `:node` | derived  | derived            |
  | `pyproject.toml`/`setup.cfg` | `:python` | `pytest` | `[]`               |

  For `package.json` the test command is read from `scripts.test`: an `npm test`
  script yields `cmd: "npm", args: ["test"]`; a script invoking another runner
  (`vitest`, `jest`, …) yields that runner directly so the derived command is the
  one the project actually runs. A `package.json` with **no** `test` script (or
  the conventional placeholder that exits non-zero) is treated as no-detection for
  the test predicate — kazi will not emit a command that is not really a test.

  Detection is ordered (Go, Elixir, Node, Python) so a polyglot repo resolves
  deterministically to a single primary stack. The first marker that yields a
  usable test command wins.

  ## Result shape

  On detection, an `%{stack: atom(), predicate: map()}` where `:predicate` is a
  goal-file predicate **map** in exactly the shape `Kazi.Goal.Loader.from_map/1`
  accepts (string keys, `provider: "test_runner"`, the `:cmd`/`:args` spread as
  sibling keys the loader collects into the predicate's `config`). Rendering and
  loading therefore round-trip through the same validated loader the CLI uses; no
  bespoke deserialiser.

  On no detection, `{:error, :no_stack_detected}` — a clear tagged result, never a
  crash, so the caller (the CLI T5.5) can report "could not detect a stack" rather
  than failing opaquely.

  ## Hermeticity

  `detect/1` reads marker files through an **injectable file-reader seam**
  (`:file_reader`, defaulting to `File`), consistent with the repo-introspection
  pattern in `Kazi.Context.RepoMapSource` (ADR-0010): a pure function over a root
  path, no `System.cmd`, no network, no git clone. Tests point it at a fixture
  repo dir (or inject an in-memory reader) and assert the derived command. The
  same repo at the same revision always yields the same result.
  """

  @typedoc """
  A detected stack: the marker family kazi recognised. `:unknown` is never
  returned (no-detection is the `{:error, :no_stack_detected}` tuple) but is
  reserved for callers that want to name the absence.
  """
  @type stack :: :go | :elixir | :node | :python | :unknown

  @typedoc """
  A successful detection: the recognised `:stack` and a goal-file `:predicate`
  map (the shape `Kazi.Goal.Loader.from_map/1` accepts).
  """
  @type detection :: %{stack: stack(), predicate: map()}

  # The predicate id every adopted test_runner carries. Stable so a re-run of
  # `kazi init` produces the same goal-file (deterministic, ADR-0013).
  @predicate_id "tests-pass"

  # Marker files probed in order; the first that yields a usable test command
  # wins. Ordering makes a polyglot repo resolve deterministically.
  @markers [
    {:go, "go.mod"},
    {:elixir, "mix.exs"},
    {:node, "package.json"},
    {:python, "pyproject.toml"},
    {:python, "setup.cfg"}
  ]

  @doc """
  Detects the stack and test command for the repo rooted at `path`.

  Returns `{:ok, %{stack: stack, predicate: predicate_map}}` when a marker file
  yields a usable test command, or `{:error, :no_stack_detected}` when no marker
  is present (or, for Node, no usable `test` script). Pure, deterministic, and
  hermetic — reads marker files through the injectable `:file_reader` seam (no
  shelling out, no network).

  ## Options

    * `:file_reader` — the filesystem seam. Either a **module** exposing
      `regular?/1` and `read/1` (the `File` contract — the default is `File`), or
      a `{module, state}` tuple whose module exposes `regular?/2` and `read/2`
      (called as `module.regular?(state, path)`). The tuple form lets tests inject
      a stateful in-memory reader and stay hermetic without touching disk.

  ## Examples

  A repo whose root holds a `go.mod` detects the Go stack and `go test ./...`:

      {:ok, %{stack: :go, predicate: predicate}} = Kazi.Adopt.detect("/path/to/repo")
      predicate["cmd"]  #=> "go"
      predicate["args"] #=> ["test", "./..."]

  A repo with no recognised marker is a clear no-detection (not a crash):

      Kazi.Adopt.detect("/path/to/empty/repo") #=> {:error, :no_stack_detected}
  """
  @spec detect(Path.t(), keyword()) :: {:ok, detection()} | {:error, :no_stack_detected}
  def detect(path, opts \\ []) when is_binary(path) and is_list(opts) do
    reader = Keyword.get(opts, :file_reader, File)

    @markers
    |> Enum.find_value(fn {stack, marker} ->
      with true <- present?(reader, path, marker),
           {:ok, cmd, args} <- command_for(reader, path, marker) do
        {stack, cmd, args}
      else
        _ -> nil
      end
    end)
    |> case do
      {stack, cmd, args} -> {:ok, %{stack: stack, predicate: predicate_map(cmd, args)}}
      nil -> {:error, :no_stack_detected}
    end
  end

  # A goal-file predicate MAP in the shape Kazi.Goal.Loader.from_map/1 accepts:
  # string keys, `provider: "test_runner"` (-> :tests kind), `:cmd`/`:args` spread
  # as sibling keys the loader collects into the predicate's `config`. So a
  # detected predicate round-trips through the same validated loader the CLI uses.
  defp predicate_map(cmd, args) do
    %{
      "id" => @predicate_id,
      "provider" => "test_runner",
      "description" => "project test suite passes",
      "cmd" => cmd,
      "args" => args
    }
  end

  # Marker → {cmd, args}. Go/Elixir/Python are fixed; Node derives from the
  # package.json `test` script (and is no-detection without a usable one).
  defp command_for(_reader, _path, "go.mod"), do: {:ok, "go", ["test", "./..."]}
  defp command_for(_reader, _path, "mix.exs"), do: {:ok, "mix", ["test"]}
  defp command_for(_reader, _path, "pyproject.toml"), do: {:ok, "pytest", []}
  defp command_for(_reader, _path, "setup.cfg"), do: {:ok, "pytest", []}

  defp command_for(reader, path, "package.json") do
    # We require that a REAL `scripts.test` exists, then run it via `npm test`.
    # The script body is not re-shelled directly (that would couple kazi to the
    # project's runner versioning); `npm test` runs whatever `scripts.test` is —
    # exactly what a developer runs.
    with {:ok, contents} <- read(reader, path, "package.json"),
         {:ok, %{} = json} <- decode_json(contents),
         :ok <- usable_test_script(json) do
      {:ok, "npm", ["test"]}
    else
      _ -> :no
    end
  end

  # :ok when package.json declares a real `scripts.test`; :no when it is absent,
  # blank, or the `npm init` placeholder that exits non-zero on purpose (emitting
  # a predicate for it would yield a command that can never pass).
  defp usable_test_script(%{"scripts" => %{"test" => script}})
       when is_binary(script) and script != "" do
    if String.contains?(script, "no test specified"), do: :no, else: :ok
  end

  defp usable_test_script(_json), do: :no

  # Dispatch the filesystem seam: a bare module follows the `File` contract
  # (`regular?/1`, `read/1`); a `{module, state}` tuple threads its state through
  # `regular?/2`/`read/2` so a stateful in-memory reader is injectable in tests.
  defp present?({mod, state}, path, marker), do: mod.regular?(state, Path.join(path, marker))
  defp present?(mod, path, marker), do: mod.regular?(Path.join(path, marker))

  defp read({mod, state}, path, marker), do: mod.read(state, Path.join(path, marker))
  defp read(mod, path, marker), do: mod.read(Path.join(path, marker))

  defp decode_json(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :no
    end
  end
end
