defmodule Kazi.Bus.TeamIdTest do
  @moduledoc """
  T65.1 (#1430): canonical team derivation.

  UNTAGGED tests (always run, no NATS): the URL-normalization identity
  (ssh/https/scp forms of one repo collapse to a single slug), the fixed `t-`
  prefix that kills the leading-dash class, and the no-origin path fallback with
  its machine-local notice -- all against real fixture git repos in a tmp dir.

  `:nats`-TAGGED tests exercise the join path end-to-end against a real
  JetStream server: argless `bus join` lands the session in the derived team
  (recorded `derived=true`), and explicit `join -- <team>` still works verbatim
  (recorded `derived=false`).
  """
  use ExUnit.Case, async: false

  alias Kazi.Bus
  alias Kazi.Bus.TeamId

  # ===========================================================================
  # Untagged: URL normalization -- the identity acc
  # ===========================================================================

  describe "slug_from_url/1 normalization" do
    test "ssh scp-like, https, and ssh-scheme forms of one repo map to ONE slug" do
      scp = TeamId.slug_from_url("git@github.com:Org/Repo.git")
      https = TeamId.slug_from_url("https://github.com/org/repo")
      ssh = TeamId.slug_from_url("ssh://git@github.com/org/repo.git")

      assert scp == "t-github.com-org-repo"
      assert scp == https
      assert https == ssh
    end

    test "credentials in an https URL are stripped (same slug as the clean form)" do
      assert TeamId.slug_from_url("https://user:token@github.com/org/repo.git") ==
               TeamId.slug_from_url("https://github.com/org/repo")
    end

    test "a trailing slash and case differences do not change the slug" do
      assert TeamId.slug_from_url("https://GitHub.com/Org/Repo/") ==
               "t-github.com-org-repo"
    end

    test "the slug NEVER begins with `-` (fixed t- prefix), even for odd hosts" do
      for url <- [
            "git@github.com:Org/Repo.git",
            "https://github.com/org/repo",
            "ssh://git@example.com/-weird/-repo.git",
            "https://gitlab.example.com/group/sub/repo.git"
          ] do
        slug = TeamId.slug_from_url(url)
        assert String.starts_with?(slug, "t-")
        refute String.starts_with?(slug, "-")
      end
    end

    test "a self-hosted host with a nested path slugs each segment with a dash" do
      assert TeamId.slug_from_url("git@gitlab.example.com:group/sub/repo.git") ==
               "t-gitlab.example.com-group-sub-repo"
    end
  end

  # ===========================================================================
  # Untagged: derive/1 against real fixture git repos
  # ===========================================================================

  describe "derive/1 with a git origin" do
    test "derives the origin slug from a fixture repo's origin remote" do
      dir = init_repo_with_origin("git@github.com:Org/Repo.git")

      assert %{slug: "t-github.com-org-repo", source: :origin, notice: nil} =
               TeamId.derive(cwd: dir)
    end

    test "the explicit origin_url override bypasses git entirely" do
      assert %{slug: "t-github.com-org-repo", source: :origin, notice: nil} =
               TeamId.derive(origin_url: "https://github.com/org/repo")
    end
  end

  describe "derive/1 with no origin remote" do
    test "falls back to a t- prefixed path slug with a machine-local notice" do
      dir = init_repo_without_origin()

      assert %{slug: slug, source: :local, notice: notice} = TeamId.derive(cwd: dir)
      assert String.starts_with?(slug, "t-")
      refute String.starts_with?(slug, "-")
      assert notice =~ "machine-local"
      assert notice =~ slug
    end
  end

  # ===========================================================================
  # :nats -- the join path end-to-end
  # ===========================================================================

  describe "join against a real NATS JetStream server" do
    @describetag :nats

    setup do
      {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
      {:ok, conn} = Gnat.start_link(%{host: host, port: port})
      on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
      :ok = Kazi.Bus.Provision.provision(conn)
      %{conn: conn}
    end

    test "argless join lands the session in the DERIVED team, recorded derived=true",
         %{conn: conn} do
      dir = init_repo_with_origin("git@github.com:Org/Repo.git")
      session = unique_session()

      assert {:ok, %{slug: "t-github.com-org-repo"}} =
               Bus.join_derived(conn: conn, session: session, scope: "machine", cwd: dir)

      assert {:ok, sessions} =
               Bus.who(conn: conn, scope: "machine", team: "t-github.com-org-repo")

      row = Enum.find(sessions, &(&1["session"] == session))
      assert row["team"] == "t-github.com-org-repo"
      assert row["derived"] == true
    end

    test "explicit join -- <team> still works verbatim, recorded derived=false",
         %{conn: conn} do
      session = unique_session()
      team = "legacy-free-form-team-#{System.unique_integer([:positive])}"

      assert :ok =
               Bus.join(team, conn: conn, session: session, scope: "machine", derived: false)

      assert {:ok, sessions} = Bus.who(conn: conn, scope: "machine", team: team)
      row = Enum.find(sessions, &(&1["session"] == session))
      assert row["team"] == team
      assert row["derived"] == false
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp init_repo_with_origin(url) do
    dir = init_repo_without_origin()
    {_out, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", url])
    dir
  end

  defp init_repo_without_origin do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kazi_teamid_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {_out, 0} = System.cmd("git", ["-C", dir, "init", "--quiet"])
    dir
  end

  defp unique_session, do: "s-teamid-#{System.unique_integer([:positive])}"

  defp parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end
