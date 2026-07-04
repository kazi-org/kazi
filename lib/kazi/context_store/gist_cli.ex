defmodule Kazi.ContextStore.GistCLI do
  @moduledoc """
  The first `Kazi.ContextStore` provider (T35.2, ADR-0045 §2): a CLI adapter that
  shells to the `gist` binary (`sirerun/gist`, Apache-2.0) — `gist index`,
  `gist search --budget N`, `gist stats`.

  The CLI adapter keeps the integration language-agnostic (gist is a Go tool) and
  is enough for a useful MVP; a persistent sidecar or native protocol can come
  later behind the same behaviour.

  ## PATH detection + graceful degradation

  The binary is resolved via `System.find_executable/1` (overridable with
  `:gist_bin`). When `gist` is **not on PATH**, every callback returns
  `{:error, :gist_not_available}` — the store is *disabled*, never a crash. The
  caller that wires this in (T35.4/T35.5) treats that error as "no store, proceed",
  so a run on a machine without `gist` is unaffected (ADR-0045 §2). This is the
  honest counterpart to `Kazi.ContextStore.NoOp`: NoOp is *off by config*, a
  missing binary is *off by environment*.

  ## Persistence: in-memory does NOT survive across CLI calls

  `gist`'s default store is **in-memory and per-process** — a `gist index` in one
  invocation is gone by the time a *separate* `gist search` runs (it prints
  "Using in-memory store (data will not persist)"). Cross-call persistence — which
  is the whole point of indexing on one iteration and searching on the next —
  therefore requires a shared backend: a PostgreSQL DSN. This adapter passes
  `--dsn` when one is configured via `:dsn`, else `KAZI_GIST_DSN`, else `GIST_DSN`
  (ADR-0045 §2: PostgreSQL for the long-running / multi-agent / CI case). Without a
  DSN, only a single index+search *within one process* is meaningful; the tests
  exercise the cross-call contract against a fake `gist` whose store is file-backed.

  ## Config (`opts`)

    * `:gist_bin` — the binary (default `"gist"`); a test points this at a fake.
    * `:dsn` — PostgreSQL DSN; defaults to `KAZI_GIST_DSN` / `GIST_DSN` env.
    * `:env` — extra environment forwarded to the subprocess (a `{name, value}`
      list), e.g. a fake's store directory.
    * `:cd` — working directory for the subprocess (default: the current one).
    * `:format` — index content format, `"markdown"` (default) or `"plaintext"`.
    * `:limit` — `gist search --limit` (default: gist's own default of 5).
    * `:source` — `gist search --source` filter, and the snippet's `:source`.
    * `:timeout_ms` — kill an overrunning `gist` call (default: no timeout).
  """

  @behaviour Kazi.ContextStore

  import Bitwise, only: [&&&: 2]

  alias Kazi.ContextStore.Snippet
  alias Kazi.Providers.CommandRunner

  @no_results "No results found"

  @impl true
  @spec index(String.t(), String.t(), keyword()) ::
          {:ok, Kazi.ContextStore.index_result()} | {:error, term()}
  def index(label, content, opts) when is_binary(label) and is_binary(content) do
    with {:ok, bin} <- resolve_bin(opts) do
      path = write_artifact(label, content)

      try do
        args = ["index", path, "--format", format(opts)] ++ dsn_args(opts)

        case CommandRunner.run(bin, args, run_opts(opts), timeout(opts)) do
          {:ran, out, 0} ->
            {:ok, %{label: label, bytes: byte_size(content), chunks: parse_chunks(out)}}

          {:ran, out, code} ->
            {:error, {:gist_index_failed, code, String.trim(out)}}

          {:raised, message} ->
            {:error, {:gist_raised, message}}

          {:timeout, ms} ->
            {:error, {:gist_timeout, ms}}
        end
      after
        File.rm(path)
      end
    end
  end

  @impl true
  @spec search(String.t(), non_neg_integer(), keyword()) ::
          {:ok, [Snippet.t()]} | {:error, term()}
  def search(query, budget, opts)
      when is_binary(query) and is_integer(budget) and budget >= 0 do
    with {:ok, bin} <- resolve_bin(opts) do
      args =
        ["search", query] ++
          budget_args(budget) ++ limit_args(opts) ++ source_args(opts) ++ dsn_args(opts)

      case CommandRunner.run(bin, args, run_opts(opts), timeout(opts)) do
        {:ran, out, 0} -> {:ok, parse_search(out, opts)}
        {:ran, out, code} -> {:error, {:gist_search_failed, code, String.trim(out)}}
        {:raised, message} -> {:error, {:gist_raised, message}}
        {:timeout, ms} -> {:error, {:gist_timeout, ms}}
      end
    end
  end

  @impl true
  @spec stats(keyword()) :: {:ok, Kazi.ContextStore.stats_map()} | {:error, term()}
  def stats(opts) do
    with {:ok, bin} <- resolve_bin(opts) do
      case CommandRunner.run(bin, ["stats"] ++ dsn_args(opts), run_opts(opts), timeout(opts)) do
        {:ran, out, 0} -> {:ok, parse_stats(out)}
        {:ran, out, code} -> {:error, {:gist_stats_failed, code, String.trim(out)}}
        {:raised, message} -> {:error, {:gist_raised, message}}
        {:timeout, ms} -> {:error, {:gist_timeout, ms}}
      end
    end
  end

  # --- binary resolution -----------------------------------------------------

  @spec resolve_bin(keyword()) :: {:ok, String.t()} | {:error, :gist_not_available}
  defp resolve_bin(opts) do
    bin = Keyword.get(opts, :gist_bin, "gist")

    cond do
      # A path form (a test fixture, or an explicit install path): check it directly.
      String.contains?(bin, "/") ->
        if executable?(bin), do: {:ok, bin}, else: {:error, :gist_not_available}

      # A bare name: resolve against PATH.
      true ->
        case System.find_executable(bin) do
          nil -> {:error, :gist_not_available}
          resolved -> {:ok, resolved}
        end
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end

  # --- argument assembly -----------------------------------------------------

  defp format(opts), do: Keyword.get(opts, :format, "markdown")

  defp budget_args(0), do: []
  defp budget_args(budget), do: ["--budget", Integer.to_string(budget)]

  defp limit_args(opts) do
    case Keyword.get(opts, :limit) do
      n when is_integer(n) and n > 0 -> ["--limit", Integer.to_string(n)]
      _ -> []
    end
  end

  defp source_args(opts) do
    case Keyword.get(opts, :source) do
      s when is_binary(s) and s != "" -> ["--source", s]
      _ -> []
    end
  end

  defp dsn_args(opts) do
    case dsn(opts) do
      nil -> []
      "" -> []
      dsn -> ["--dsn", dsn]
    end
  end

  defp dsn(opts) do
    Keyword.get(opts, :dsn) || System.get_env("KAZI_GIST_DSN") || System.get_env("GIST_DSN")
  end

  defp run_opts(opts) do
    base = [stderr_to_stdout: true]
    base = if cd = Keyword.get(opts, :cd), do: [{:cd, cd} | base], else: base
    if env = Keyword.get(opts, :env), do: [{:env, env} | base], else: base
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms)

  # --- output parsing --------------------------------------------------------

  # `gist index <file>: N chunks (M code)` — pull the chunk count; default 0.
  defp parse_chunks(out) do
    case Regex.run(~r/:\s*(\d+)\s+chunks?/, out) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  # gist already applied the budget + ranking; pass its result through as one
  # snippet rather than guessing an unverified per-result text format. The empty
  # case ("No results found") is the verified off-result.
  defp parse_search(out, opts) do
    trimmed = String.trim(out) |> strip_inmemory_notice()

    if trimmed == "" or String.contains?(trimmed, @no_results) do
      []
    else
      [Snippet.new(trimmed, source: Keyword.get(opts, :source), bytes: byte_size(trimmed))]
    end
  end

  # Parse the verified `gist stats` byte lines ("Bytes indexed:  1.2 KB"), tolerant
  # of human units; counters absent ⇒ 0.
  defp parse_stats(out) do
    indexed = parse_bytes_line(out, "Bytes indexed")
    returned = parse_bytes_line(out, "Bytes returned")
    saved = parse_bytes_line(out, "Bytes saved")

    %{
      provider: :gist,
      indexed_bytes: indexed,
      returned_bytes: returned,
      saved_bytes: saved
    }
  end

  defp parse_bytes_line(out, label) do
    case Regex.run(~r/#{Regex.escape(label)}:\s*([\d.]+)\s*([KMGT]?B)/, out) do
      [_, num, unit] -> to_bytes(num, unit)
      _ -> 0
    end
  end

  defp to_bytes(num, unit) do
    value = String.to_float(ensure_decimal(num))
    round(value * unit_factor(unit))
  end

  defp ensure_decimal(num), do: if(String.contains?(num, "."), do: num, else: num <> ".0")

  defp unit_factor("B"), do: 1
  defp unit_factor("KB"), do: 1_000
  defp unit_factor("MB"), do: 1_000_000
  defp unit_factor("GB"), do: 1_000_000_000
  defp unit_factor("TB"), do: 1_000_000_000_000

  defp strip_inmemory_notice(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "Using in-memory store"))
    |> Enum.join("\n")
    |> String.trim()
  end

  # --- artifact staging ------------------------------------------------------

  # gist indexes FILES; stage the content under a temp file whose basename encodes
  # the (sanitised) label for traceability, then index it. A unique suffix keeps
  # concurrent indexes of the SAME label from colliding on one staging path (one
  # call's post-index `File.rm` would otherwise pull the file out from under
  # another's `gist index`).
  #
  # Indexed content can carry repo-sensitive evidence, and the default umask
  # leaves both the dir and the file world-readable in a shared /tmp — a
  # co-tenant on the host could read it before the post-index `File.rm` (deep
  # review L4). Lock the dir to 0700 and the file to 0600 before any content is
  # written to it.
  defp write_artifact(label, content) do
    dir = Path.join(System.tmp_dir!(), "kazi-context-store")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    name =
      sanitize(label) <> "-" <> Integer.to_string(System.unique_integer([:positive])) <> ".md"

    path = Path.join(dir, name)
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, content)
    path
  end

  defp sanitize(label) do
    label
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
    |> String.slice(0, 180)
  end
end
