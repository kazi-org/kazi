defmodule Kazi.Providers.OssHygieneTest do
  # Tier 1: the pure scanner (leak_kind/scan_diff) ported from the CI guard.
  # Tier 2: the real boundary — an actual git diff over a real fixture repo with
  # real leak patterns (T44.7, E29/ADR-0034, UC-058).
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateResult}
  alias Kazi.Goal.Loader
  alias Kazi.Providers.OssHygiene

  # ── Tier 1: the pure scanner ────────────────────────────────────────────────

  describe "leak_kind/2" do
    test "flags a private IP" do
      assert OssHygiene.leak_kind("host = 192.168.5.5", []) == :private_ip
      assert OssHygiene.leak_kind("10.1.2.3", []) == :private_ip
      assert OssHygiene.leak_kind("172.16.0.1", []) == :private_ip
    end

    test "flags an absolute home path" do
      assert OssHygiene.leak_kind("cd /Users/someone/Code", []) == :home_path
      assert OssHygiene.leak_kind("/home/dev/project", []) == :home_path
    end

    test "flags a configured codename (case-insensitive, whole token)" do
      assert OssHygiene.leak_kind("deploy to Project-Nimbus now", ["project-nimbus"]) == :codename
      # A substring of a larger token is NOT a hit.
      assert OssHygiene.leak_kind("projectnimbusish", ["project-nimbus"]) == nil
    end

    test "allow-lists RFC-5737 example IPs, loopback, and placeholder home paths" do
      assert OssHygiene.leak_kind("host = 192.0.2.5", []) == nil
      assert OssHygiene.leak_kind("198.51.100.9", []) == nil
      assert OssHygiene.leak_kind("203.0.113.1", []) == nil
      assert OssHygiene.leak_kind("127.0.0.1", []) == nil
      assert OssHygiene.leak_kind("/Users/<name>/Code", []) == nil
      assert OssHygiene.leak_kind("/home/USER/x", []) == nil
    end

    test "an inline leak-guard:allow marker exempts the line" do
      assert OssHygiene.leak_kind("host 192.168.5.5 # leak-guard:allow", []) == nil
    end

    test "a clean line is nil" do
      assert OssHygiene.leak_kind("just a normal line of code", ["project-nimbus"]) == nil
    end
  end

  describe "scan_diff/2" do
    test "reports each added leak with its path and new-file line number" do
      diff = """
      diff --git a/secrets.txt b/secrets.txt
      new file mode 100644
      --- /dev/null
      +++ b/secrets.txt
      @@ -0,0 +1,3 @@
      +clean first line
      +host = 192.168.5.5
      +another clean line
      """

      assert [hit] = OssHygiene.scan_diff(diff, [])
      assert hit.path == "secrets.txt"
      assert hit.line == 2
      assert hit.kind == :private_ip
    end
  end

  # ── Tier 2: the real git boundary ───────────────────────────────────────────

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_oss_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git(dir, ["init", "-q"])
    git(dir, ["config", "user.email", "t@example.test"])
    git(dir, ["config", "user.name", "kazi test"])
    File.write!(Path.join(dir, "README.md"), "seed\n")
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "seed"])
    {base, 0} = git(dir, ["rev-parse", "HEAD"])

    {:ok, dir: dir, base: String.trim(base)}
  end

  defp add_commit!(dir, path, contents) do
    File.write!(Path.join(dir, path), contents)
    git(dir, ["add", "."])
    git(dir, ["commit", "-q", "-m", "change"])
  end

  defp evaluate(dir, base, config \\ %{}) do
    predicate = Predicate.new("hygiene", :oss_hygiene, config: Map.put(config, :base_ref, base))
    OssHygiene.evaluate(predicate, %{workspace: dir})
  end

  test "a diff ADDING a private IP FAILS, naming the exact file:line", %{dir: dir, base: base} do
    add_commit!(dir, "config.txt", "one\ntwo\nhost 192.168.9.9\n")

    result = evaluate(dir, base)

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.count == 1
    assert [%{path: "config.txt", line: 3, kind: :private_ip}] = result.evidence.hits
  end

  test "a SCRUBBED diff (only allow-listed patterns) PASSES", %{dir: dir, base: base} do
    add_commit!(dir, "docs.md", "example host 192.0.2.5\nplaceholder /Users/<name>/x\n")

    result = evaluate(dir, base)

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.count == 0
  end

  test "the codename list is CONFIGURABLE per goal-file", %{dir: dir, base: base} do
    add_commit!(dir, "deploy.md", "roll out to project-nimbus tonight\n")

    # Default patterns do NOT catch an arbitrary codename.
    assert %PredicateResult{status: :pass} = evaluate(dir, base)

    # With the codename configured, the same line FAILS.
    result = evaluate(dir, base, %{codenames: ["project-nimbus"]})
    assert %PredicateResult{status: :fail} = result
    assert [%{path: "deploy.md", line: 1, kind: :codename}] = result.evidence.hits
  end

  test "an unresolvable base ref is an :error, not a :fail", %{dir: dir} do
    result = evaluate(dir, "origin/does-not-exist")
    assert %PredicateResult{status: :error} = result
    assert match?({:base_unresolvable, _}, result.evidence.reason)
  end

  # ── loader + schema ─────────────────────────────────────────────────────────

  describe "loader + schema" do
    test "a well-formed oss_hygiene predicate loads" do
      data = %{
        "id" => "g",
        "predicate" => [
          %{
            "id" => "no-leaks",
            "provider" => "oss_hygiene",
            "base_ref" => "origin/main",
            "codenames" => ["project-nimbus"]
          }
        ]
      }

      assert {:ok, %Goal{predicates: [predicate]}} = Loader.from_map(data)
      assert predicate.kind == :oss_hygiene
      assert predicate.config.codenames == ["project-nimbus"]
    end

    test "a non-list codenames is a load error" do
      data = %{
        "id" => "g",
        "predicate" => [%{"id" => "p", "provider" => "oss_hygiene", "codenames" => "nope"}]
      }

      assert {:error, reason} = Loader.from_map(data)
      assert reason =~ "codenames"
    end

    test "kazi schema oss_hygiene lists the config keys" do
      assert {:ok, schema} = Kazi.Predicate.Schema.fetch("oss_hygiene")
      names = Enum.map(schema.keys, & &1.name)
      assert "codenames" in names
      assert "base_ref" in names
      assert "oss_hygiene" in Kazi.Predicate.Schema.kinds()
    end
  end
end
