defmodule Kazi.ContextStore.GistInit do
  @moduledoc """
  Project-local setup for the Gist context-store provider (T35.8, ADR-0045 §8):
  the work behind `kazi init --with-gist`.

  Three steps, all **project-local** — nothing here ever touches a global agent
  config (`~/.claude`, a user-level `.mcp.json`, …). The whole point of the flag
  is to opt a *single repo* into the Gist context store without changing how any
  other project on the machine behaves:

    1. **Verify the dependency** — shell `gist doctor` to confirm the `gist`
       binary (`sirerun/gist`, Apache-2.0) is installed and its runtime is healthy.
       When `gist` is **not on PATH** this returns `{:error, :gist_not_available}`
       so the caller reports a missing dep cleanly — never a crash.
    2. **Write `<repo>/.kazi/context.toml`** — the project-local context-store
       config naming the provider. This file is owned by kazi's context-store
       layer; the writer is idempotent (a repeat run that already names `gist`
       leaves it untouched) and preserves an existing `dsn` value.
    3. **Register the Gist MCP server** — additively merge a `gist` server entry
       (`gist serve`, MCP over stdio) into the repo's `.mcp.json`, mirroring the
       additive merge `Kazi.MCP.ClientConfig` does for the kazi server. Any servers
       already declared are preserved; an unparseable `.mcp.json` is a hard error
       rather than a silent clobber.

  Cross-call persistence (index on one iteration, search on the next) needs a
  shared PostgreSQL backend, so the caller *recommends* setting `#{"KAZI_GIST_DSN"}`
  — it is never written into the repo (a DSN can carry credentials, and the OSS
  repo must stay clean). See `Kazi.ContextStore.GistCLI` for the DSN convention
  (`:dsn` → `KAZI_GIST_DSN` → `GIST_DSN`).

  ## Test seam

  `doctor/1` accepts `:gist_bin` (default `"gist"`), resolved exactly like
  `Kazi.ContextStore.GistCLI` (a `/`-bearing path is checked directly, a bare name
  is looked up on PATH). Tests point it at `test/support/fake_gist.sh` for the
  healthy path, or at a non-existent name for the missing-dep path. `:env`, `:cd`
  and `:timeout_ms` are forwarded to the subprocess.
  """

  import Bitwise, only: [&&&: 2]

  alias Kazi.Providers.CommandRunner

  @gist_server_name "gist"
  @gist_server_entry %{"command" => "gist", "args" => ["serve"]}
  @context_dir ".kazi"
  @context_filename "context.toml"
  @mcp_filename ".mcp.json"
  @dsn_env "KAZI_GIST_DSN"

  @doc "The server key the Gist MCP server is declared under in `.mcp.json` (`\"gist\"`)."
  @spec gist_server_name() :: String.t()
  def gist_server_name, do: @gist_server_name

  @doc ~S"""
  The Gist MCP server entry: `%{"command" => "gist", "args" => ["serve"]}` — the
  installed binary's `serve` verb, which speaks MCP/JSON-RPC over stdio.
  """
  @spec gist_server_entry() :: map()
  def gist_server_entry, do: @gist_server_entry

  @doc "The env var kazi recommends for the shared PostgreSQL DSN (`\"KAZI_GIST_DSN\"`)."
  @spec dsn_env() :: String.t()
  def dsn_env, do: @dsn_env

  @doc "The project-local context-store config path under `dir` (`<dir>/.kazi/context.toml`)."
  @spec context_path(String.t()) :: String.t()
  def context_path(dir), do: Path.join([dir, @context_dir, @context_filename])

  # --- step 1: verify the dependency -----------------------------------------

  @doc """
  Run `gist doctor` to verify the binary is installed and its runtime is healthy.

  Returns `{:ok, output}` when it runs and exits 0; `{:error, :gist_not_available}`
  when the binary is not on PATH (the missing-dep path the caller reports cleanly);
  `{:error, {:doctor_failed, code, output}}` when it runs but reports unhealthy; and
  `{:error, {:gist_raised, message}}` / `{:error, {:gist_timeout, ms}}` for a
  subprocess that could not start or overran.
  """
  @spec doctor(keyword()) ::
          {:ok, String.t()}
          | {:error,
             :gist_not_available
             | {:doctor_failed, integer(), String.t()}
             | {:gist_raised, String.t()}
             | {:gist_timeout, pos_integer()}}
  def doctor(opts \\ []) do
    with {:ok, bin} <- resolve_bin(Keyword.get(opts, :gist_bin, "gist")) do
      case CommandRunner.run(bin, ["doctor"], run_opts(opts), Keyword.get(opts, :timeout_ms)) do
        {:ran, out, 0} -> {:ok, String.trim(out)}
        {:ran, out, code} -> {:error, {:doctor_failed, code, String.trim(out)}}
        {:raised, message} -> {:error, {:gist_raised, message}}
        {:timeout, ms} -> {:error, {:gist_timeout, ms}}
      end
    end
  end

  # --- step 2: project-local context.toml ------------------------------------

  @doc """
  Write `<dir>/.kazi/context.toml` declaring the Gist context-store provider.

  Idempotent: when the file already names `provider = "gist"` it is left untouched
  (`{:ok, :present, path}`); an existing `dsn` value is preserved when present.
  Returns `{:ok, :created | :updated | :present, path}` or `{:error, reason}` (an
  unparseable existing file is `{:error, {:malformed_context_toml, path}}` — never
  a silent clobber).
  """
  @spec write_context_toml(String.t()) ::
          {:ok, :created | :updated | :present, String.t()} | {:error, term()}
  def write_context_toml(dir) when is_binary(dir) do
    path = context_path(dir)

    with {:ok, existed?, existing} <- read_context_toml(path) do
      store = Map.get(existing, "context_store", %{})
      dsn = Map.get(store, "dsn")

      if existed? and Map.get(store, "provider") == @gist_server_name do
        {:ok, :present, path}
      else
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, render_context_toml(dsn)) do
          {:ok, if(existed?, do: :updated, else: :created), path}
        else
          {:error, reason} -> {:error, {:context_write_failed, path, reason}}
        end
      end
    end
  end

  # A missing file is an empty config (existed? false). A present-but-unparseable
  # file is a hard error — we will not clobber a context.toml we cannot read.
  @spec read_context_toml(String.t()) :: {:ok, boolean(), map()} | {:error, term()}
  defp read_context_toml(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, false, %{}}

      {:ok, contents} ->
        case Toml.decode(contents) do
          {:ok, config} when is_map(config) -> {:ok, true, config}
          {:ok, _other} -> {:error, {:malformed_context_toml, path}}
          {:error, _reason} -> {:error, {:malformed_context_toml, path}}
        end

      {:error, reason} ->
        {:error, {:context_read_failed, path, reason}}
    end
  end

  # Deterministic hand-render — the file is single-purpose (context-store config),
  # so a small fixed template, not an arbitrary TOML encoder. A pre-existing DSN is
  # preserved as an active key; otherwise the DSN line stays commented so no
  # credential is ever written into the repo by default (recommend the env var).
  defp render_context_toml(dsn) do
    dsn_line =
      case dsn do
        d when is_binary(d) and d != "" -> "dsn = #{inspect(d)}\n"
        _ -> "# dsn = \"postgres://USER:PASS@HOST:5432/gist\"\n"
      end

    """
    # kazi context-store config (ADR-0045). Written by `kazi init --with-gist`.
    # Project-local: this opts THIS repo into the Gist context store. For
    # cross-iteration persistence, prefer setting the #{@dsn_env} env var
    # (a DSN can carry credentials; keep it out of version control).
    [context_store]
    provider = "#{@gist_server_name}"
    #{dsn_line}\
    """
  end

  # --- step 3: project-local MCP config --------------------------------------

  @doc """
  Additively merge the Gist MCP server entry into `<dir>/.mcp.json`, preserving any
  servers or top-level keys already there and writing only when the file changes
  (idempotent). Mirrors `Kazi.MCP.ClientConfig.ensure_in_dir/1` for the kazi server.

  Returns `{:ok, :created | :merged | :present, path}` or `{:error, reason}` when an
  existing `.mcp.json` cannot be parsed (we will not clobber one we cannot read).
  """
  @spec ensure_mcp(String.t()) ::
          {:ok, :created | :merged | :present, String.t()} | {:error, term()}
  def ensure_mcp(dir) when is_binary(dir) do
    path = Path.join(dir, @mcp_filename)

    with {:ok, existed?, existing} <- read_mcp_config(path) do
      servers = Map.get(existing, "mcpServers", %{})

      if Map.get(servers, @gist_server_name) == @gist_server_entry do
        {:ok, :present, path}
      else
        merged =
          Map.put(existing, "mcpServers", Map.put(servers, @gist_server_name, @gist_server_entry))

        with :ok <- write_mcp_config(path, merged) do
          {:ok, if(existed?, do: :merged, else: :created), path}
        end
      end
    end
  end

  # A missing file is an empty config. A present-but-malformed file is a hard error.
  @spec read_mcp_config(String.t()) :: {:ok, boolean(), map()} | {:error, term()}
  defp read_mcp_config(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, false, %{}}

      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, config} when is_map(config) -> {:ok, true, config}
          {:ok, _other} -> {:error, {:malformed_mcp_json, path}}
          {:error, reason} -> {:error, {:invalid_mcp_json, path, reason}}
        end

      {:error, reason} ->
        {:error, {:mcp_read_failed, path, reason}}
    end
  end

  @spec write_mcp_config(String.t(), map()) :: :ok | {:error, term()}
  defp write_mcp_config(path, config) do
    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        with :ok <- File.mkdir_p(Path.dirname(path)) do
          File.write(path, json <> "\n")
        end

      {:error, reason} ->
        {:error, {:mcp_encode_failed, path, reason}}
    end
  end

  # --- binary resolution (mirrors Kazi.ContextStore.GistCLI) -----------------

  @spec resolve_bin(String.t()) :: {:ok, String.t()} | {:error, :gist_not_available}
  defp resolve_bin(bin) do
    cond do
      String.contains?(bin, "/") ->
        if executable?(bin), do: {:ok, bin}, else: {:error, :gist_not_available}

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

  defp run_opts(opts) do
    base = [stderr_to_stdout: true]
    base = if cd = Keyword.get(opts, :cd), do: [{:cd, cd} | base], else: base
    if env = Keyword.get(opts, :env), do: [{:env, env} | base], else: base
  end
end
