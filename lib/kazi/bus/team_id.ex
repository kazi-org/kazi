defmodule Kazi.Bus.TeamId do
  @moduledoc """
  T65.1 (#1430): canonical team derivation for the session bus.

  A team is DERIVED from the workspace, never typed. `derive/1` reads the
  workspace's `git remote get-url origin`, normalizes every equivalent URL form
  (ssh scp-like `git@host:org/repo.git`, `https://host/org/repo`, and
  `ssh://git@host/org/repo.git`) to ONE identity -- scheme, credentials, and the
  `.git` suffix stripped, host+path case-folded -- and slugs it as
  `t-<host>-<org>-<repo>`. The fixed `t-` prefix is load-bearing: no derived slug
  can ever begin with `-`, which structurally kills the leading-dash team-string
  class that split `@team` delivery three ways in one day (#1430 failure mode 3).

  With no origin remote the team falls back to the canonicalized repo-root
  realpath, slugged the same way (still `t-` prefixed), and `derive/1` returns a
  one-line notice that the team is machine-local -- not shared across checkouts
  or machines the way an origin-derived team is.

  This module is pure derivation: it does NOT write presence or touch the daemon.
  The join path (`Kazi.Bus.join/2`, `Kazi.CLI`) consumes the result.
  """

  @typedoc """
  A derived team identity.

    * `:slug` -- the `t-`-prefixed team slug (never begins with `-`).
    * `:source` -- `:origin` (from the git origin URL) or `:local` (repo-root
      path fallback when there is no origin remote).
    * `:notice` -- a one-line human notice for the `:local` case, else `nil`.
  """
  @type t :: %{
          slug: String.t(),
          source: :origin | :local,
          notice: String.t() | nil
        }

  @default_timeout_ms 3_000

  @doc """
  Derives the team identity for a workspace.

  Options:

    * `:cwd` -- the workspace directory (default: current working directory).
    * `:origin_url` -- an explicit origin URL to normalize instead of shelling
      out to git; the seam the derivation tests drive the normalization through.
    * `:timeout_ms` -- git-call timeout (default #{@default_timeout_ms}ms).

  Always succeeds: an origin URL yields an `:origin` slug, its absence yields the
  `:local` path-fallback slug with a machine-local notice.
  """
  @spec derive(keyword()) :: t()
  def derive(opts \\ []) do
    case origin_url(opts) do
      {:ok, url} ->
        %{slug: slug_from_url(url), source: :origin, notice: nil}

      :none ->
        slug = slug_from_path(repo_root(opts))

        %{
          slug: slug,
          source: :local,
          notice:
            "no git origin remote; team '#{slug}' is machine-local " <>
              "(not shared across checkouts or machines)"
        }
    end
  end

  @doc """
  Normalizes a git remote URL to the canonical `t-<host>-<org>-<repo>` slug.

  ssh scp-like (`git@github.com:Org/Repo.git`), https
  (`https://github.com/org/repo`), and ssh-scheme
  (`ssh://git@github.com/org/repo.git`) forms of the same repo all map to ONE
  identical slug. The returned slug always begins with `t-`.
  """
  @spec slug_from_url(String.t()) :: String.t()
  def slug_from_url(url) when is_binary(url) do
    {host, path} = url |> String.trim() |> split_host_path()

    identity =
      [host | path_segments(path)]
      |> Enum.map(&String.downcase/1)
      |> Enum.join("-")

    slugify(identity)
  end

  # ---- origin lookup --------------------------------------------------------

  defp origin_url(opts) do
    case opts[:origin_url] do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _absent ->
        git_origin_url(opts)
    end
  end

  defp git_origin_url(opts) do
    cwd = opts[:cwd] || File.cwd!()
    timeout = opts[:timeout_ms] || @default_timeout_ms

    task =
      Task.async(fn ->
        System.cmd("git", ["-C", cwd, "remote", "get-url", "origin"], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        case String.trim(out) do
          "" -> :none
          url -> {:ok, url}
        end

      _no_origin ->
        :none
    end
  rescue
    _e -> :none
  end

  # The canonicalized repo-root path. `git rev-parse --show-toplevel` names the
  # repo root even from a subdir/worktree; realpath resolves symlinks so two
  # paths to the same tree derive the same machine-local slug. Falls back to the
  # realpath of cwd when git can't answer.
  defp repo_root(opts) do
    cwd = opts[:cwd] || File.cwd!()
    timeout = opts[:timeout_ms] || @default_timeout_ms

    root =
      try do
        task =
          Task.async(fn ->
            System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true)
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {out, 0}} ->
            case String.trim(out) do
              "" -> cwd
              top -> top
            end

          _not_a_repo ->
            cwd
        end
      rescue
        _e -> cwd
      end

    realpath(root)
  end

  defp realpath(path) do
    case :file.read_link_all(path) do
      {:ok, resolved} -> to_string(resolved)
      _not_a_link -> Path.expand(path)
    end
  end

  # ---- URL parsing ----------------------------------------------------------

  # Splits any accepted remote form into {host, "org/repo..."} with scheme,
  # credentials, and any port stripped.
  defp split_host_path(url) do
    cond do
      String.contains?(url, "://") ->
        uri = URI.parse(url)
        {strip_userinfo_host(uri.host, uri.userinfo), uri.path || ""}

      scp = Regex.run(~r{^(?:[^@/]+@)?([^:/]+):(.*)$}, url) ->
        [_, host, path] = scp
        {host, path}

      true ->
        # Bare `host/org/repo` with no scheme or scp colon.
        case String.split(strip_credentials(url), "/", parts: 2) do
          [host, path] -> {host, path}
          [host] -> {host, ""}
        end
    end
  end

  # URI.host already excludes userinfo; this guards the rare case a parser leaves
  # it attached and strips any port suffix.
  defp strip_userinfo_host(nil, _userinfo), do: ""

  defp strip_userinfo_host(host, _userinfo) do
    host
    |> String.split("@")
    |> List.last()
    |> String.split(":")
    |> List.first()
  end

  defp strip_credentials(str) do
    case String.split(str, "@", parts: 2) do
      [_creds, rest] -> rest
      [only] -> only
    end
  end

  # `org/repo(.git)` -> ["org", "repo"], leading/trailing slashes and the `.git`
  # suffix dropped.
  defp path_segments(path) do
    path
    |> String.trim("/")
    |> String.replace_suffix(".git", "")
    |> String.split("/", trim: true)
  end

  # ---- slugging -------------------------------------------------------------

  defp slug_from_path(path) do
    slugify(String.downcase(path))
  end

  # Fixed `t-` prefix + a filesystem/flag-safe body: every char outside
  # [a-z0-9.] collapses to a single `-`, and stray leading/trailing dashes are
  # trimmed. The prefix guarantees the result never begins with `-`.
  defp slugify(identity) do
    body =
      identity
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9.]+/, "-")
      |> String.trim("-")

    "t-" <> body
  end
end
