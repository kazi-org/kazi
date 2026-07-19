defmodule Kazi.ContextStore.RedactionTest do
  @moduledoc """
  T35.3: a planted credential is redacted BEFORE it reaches the store, a search
  never returns it, and the store path redacts with PARITY to the harness-prompt
  path (both route through `Kazi.Redaction`).
  """
  use ExUnit.Case, async: true

  alias Kazi.ContextStore
  alias Kazi.ContextStore.{GistCLI, Labels}
  alias Kazi.Harness.Prompt
  alias Kazi.PredicateResult
  alias Kazi.Redaction

  @fake Path.expand("../../support/fake_gist.sh", __DIR__)
  @secret "AKIAIOSFODNN7EXAMPLE"
  @log "migration failed\nDATABASE_URL=postgres://app:#{@secret}@db/prod\nAWS_KEY=#{@secret}"

  setup do
    store = Path.join(System.tmp_dir!(), "redact-gist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(store)
    on_exit(fn -> File.rm_rf(store) end)
    {:ok, store: store, opts: [gist_bin: @fake, env: [{"FAKE_GIST_STORE", store}]]}
  end

  describe "redact-before-index (the store never holds the secret)" do
    test "the planted credential never lands in the backing store", %{store: store, opts: opts} do
      label = Labels.run_test_log("g1", 1)
      assert {:ok, _} = ContextStore.index(label, @log, context_store: {GistCLI, opts})

      # Inspect the fake's file-backed store directly: the raw secret must be gone.
      stored = File.read!(Path.join(store, "content.dat"))
      refute stored =~ @secret
      assert stored =~ "[REDACTED]"
    end

    test "a search can never return the secret", %{opts: opts} do
      label = Labels.run_test_log("g1", 1)
      assert {:ok, _} = ContextStore.index(label, @log, context_store: {GistCLI, opts})

      assert {:ok, snippets} =
               ContextStore.search("DATABASE_URL", 400, context_store: {GistCLI, opts})

      refute Enum.any?(snippets, &(&1.text =~ @secret))
    end
  end

  describe "parity with the harness-prompt path" do
    test "the same secret is redacted in the prompt evidence" do
      failing = [{:migrate, PredicateResult.fail(%{output: @log})}]
      prompt = Prompt.build_prompt("Fix the migration", failing)

      refute prompt =~ @secret
      assert prompt =~ "[REDACTED]"
    end

    test "both egress paths apply the identical Kazi.Redaction transform", %{
      store: store,
      opts: opts
    } do
      # Prompt path output for the secret value:
      failing = [{:migrate, PredicateResult.fail(%{output: @log})}]
      prompt = Prompt.build_prompt("Fix it", failing)

      # Store path output for the same value:
      label = Labels.run_test_log("g1", 2)
      assert {:ok, _} = ContextStore.index(label, @log, context_store: {GistCLI, opts})
      stored = File.read!(Path.join(store, "content.dat"))

      # The canonical redaction both should equal:
      redacted = Redaction.redact(@log)

      # Each path contains the redacted form and neither contains the raw secret.
      assert prompt =~ redacted
      assert stored =~ redacted
      refute prompt =~ @secret
      refute stored =~ @secret
    end
  end
end
