defmodule Kazi.ContextStore.GistCLIPermsTest do
  use ExUnit.Case, async: true

  alias Kazi.ContextStore.{GistCLI, Labels}

  @fake Path.expand("../../support/fake_gist.sh", __DIR__)

  setup do
    store = Path.join(System.tmp_dir!(), "fake-gist-perms-#{System.unique_integer([:positive])}")
    File.mkdir_p!(store)
    on_exit(fn -> File.rm_rf(store) end)
    {:ok, opts: [gist_bin: @fake, env: [{"FAKE_GIST_STORE", store}]], store: store}
  end

  describe "L4: staged context-store artifacts are not world-readable" do
    test "the staged file is 0600 and its parent dir is 0700", %{opts: opts, store: store} do
      assert {:ok, _} = GistCLI.index(Labels.run_test_log("g1", 1), "sensitive evidence", opts)

      perms_file = Path.join(store, "last_artifact_perms")
      assert File.exists?(perms_file)
      [file_mode, dir_mode] = perms_file |> File.read!() |> String.trim() |> String.split(" ")

      assert file_mode == "600"
      assert dir_mode == "700"
    end
  end
end
