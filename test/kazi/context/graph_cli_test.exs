defmodule Kazi.Context.GraphCliTest do
  # Tier-2: exercises the graph CLI boundary via an injected stub executable so the
  # parser is covered without a live MCP server. Hermetic — the "binary" is a shell
  # script we write to a temp dir.
  use ExUnit.Case, async: true

  alias Kazi.Context.{GraphCli, Survey, Symbol}

  defp write_stub!(body) do
    dir = Path.join(System.tmp_dir!(), "kazi_graphcli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "graph_stub.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf!(dir) end)
    path
  end

  test "parses graph JSON into a survey with sorted edges" do
    json =
      ~s({"files":[{"path":"lib/a.ex"}],) <>
        ~s("symbols":[{"name":"f/1","path":"lib/a.ex","kind":"function",) <>
        ~s("callers":["z","a"],"callees":["m"]}],) <>
        ~s("test_sources":[{"path":"test/a_test.exs","source":"assert true"}]})

    stub = write_stub!("cat <<'EOF'\n#{json}\nEOF\n")

    assert {:ok, %Survey{origin: :graph} = survey} =
             GraphCli.survey(".", ["a"], graph_command: stub)

    assert [%{path: "lib/a.ex"}] = survey.files

    assert [%Symbol{name: "f/1", kind: :function, callers: ["a", "z"], callees: ["m"]}] =
             survey.symbols

    assert [%{path: "test/a_test.exs", source: "assert true"}] = survey.test_sources
  end

  test "a non-zero exit is an error, not a crash" do
    stub = write_stub!("echo boom >&2\nexit 1\n")
    assert {:error, {:graph_cli_failed, _}} = GraphCli.survey(".", ["a"], graph_command: stub)
  end

  test "malformed JSON is an error" do
    stub = write_stub!("echo 'not json'\n")
    assert {:error, _} = GraphCli.survey(".", ["a"], graph_command: stub)
  end

  test "a missing binary is a command_not_found error" do
    assert {:error, {:command_not_found, _}} =
             GraphCli.survey(".", ["a"], graph_command: "definitely_no_such_binary_xyz")
  end
end
