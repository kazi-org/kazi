defmodule Kazi.Loop.ErrorPermanenceTest do
  use ExUnit.Case, async: true

  alias Kazi.Loop.ErrorPermanence
  alias Kazi.PredicateResult

  doctest Kazi.Loop.ErrorPermanence

  describe "classify/1 — permanent reasons (config/wiring, can never pass without a fix)" do
    test "missing required config" do
      assert ErrorPermanence.classify(:missing_url) == :permanent
      assert ErrorPermanence.classify(:missing_cmd) == :permanent
    end

    test "no provider registered for the predicate kind" do
      assert ErrorPermanence.classify(:no_provider) == :permanent
    end

    test "unsupported predicate kind, bare atom or {tag, kind} tuple" do
      assert ErrorPermanence.classify(:unsupported_kind) == :permanent
      assert ErrorPermanence.classify({:unsupported_kind, :bogus}) == :permanent
    end

    test "malformed command config" do
      assert ErrorPermanence.classify({:invalid_cmd, 123}) == :permanent
      assert ErrorPermanence.classify({:unknown_verdict, "nonsense"}) == :permanent
    end

    test "command could not even be started (missing binary, bad cwd)" do
      assert ErrorPermanence.classify({:cmd_unrunnable, "no such file or directory"}) ==
               :permanent
    end

    test "malformed provider-level config (e.g. payload encoding)" do
      assert ErrorPermanence.classify({:invalid_config, "bad payload"}) == :permanent
    end
  end

  describe "classify/1 — transient reasons (may recover on retry, no config change needed)" do
    test "a timeout" do
      assert ErrorPermanence.classify({:timeout_ms, 5_000}) == :transient
    end

    test "a non-zero evidence exit" do
      assert ErrorPermanence.classify({:error_exit, 1}) == :transient
      assert ErrorPermanence.classify({:tool_unrunnable, 2}) == :transient
      assert ErrorPermanence.classify({:runner_failed, 1}) == :transient
      assert ErrorPermanence.classify({:query_failed, 1}) == :transient
    end

    test "a connection failure reported as an inspected string" do
      assert ErrorPermanence.classify("econnrefused") == :transient
      assert ErrorPermanence.classify("{:failed_connect, [{:to_address, ~c\"x\"}]}") == :transient
    end

    test "unparseable or malformed runner output (a runtime hiccup, not declared config)" do
      assert ErrorPermanence.classify({:invalid_runner_result, %{}}) == :transient
      assert ErrorPermanence.classify({:unparseable_runner_output, "bad json"}) == :transient
    end
  end

  describe "classify/1 — unknown reasons default :transient (never assume permanent)" do
    test "an unrecognised atom" do
      assert ErrorPermanence.classify(:something_never_seen_before) == :transient
    end

    test "an unrecognised tuple" do
      assert ErrorPermanence.classify({:some_new_reason, 42}) == :transient
    end

    test "nil, maps, and other arbitrary terms" do
      assert ErrorPermanence.classify(nil) == :transient
      assert ErrorPermanence.classify(%{unexpected: true}) == :transient
      assert ErrorPermanence.classify(42) == :transient
    end
  end

  describe "permanent?/1 and transient?/1" do
    test "agree with classify/1" do
      assert ErrorPermanence.permanent?(:missing_url)
      refute ErrorPermanence.transient?(:missing_url)

      refute ErrorPermanence.permanent?({:timeout_ms, 100})
      assert ErrorPermanence.transient?({:timeout_ms, 100})
    end
  end

  describe "classify_result/1 — reads the :reason out of a PredicateResult's evidence" do
    test "an :error result with a permanent reason" do
      result = PredicateResult.error(%{reason: :missing_url})
      assert ErrorPermanence.classify_result(result) == :permanent
    end

    test "an :error result with a transient reason" do
      result = PredicateResult.error(%{reason: {:timeout_ms, 100}})
      assert ErrorPermanence.classify_result(result) == :transient
    end

    test "an :error result with no :reason key defaults :transient" do
      result = PredicateResult.error(%{})
      assert ErrorPermanence.classify_result(result) == :transient
    end
  end

  describe "purity — no I/O, deterministic" do
    test "classify/1 is a pure function of its input" do
      reasons = [:missing_url, {:timeout_ms, 100}, "econnrefused", :unheard_of]

      for reason <- reasons do
        assert ErrorPermanence.classify(reason) == ErrorPermanence.classify(reason)
      end
    end
  end
end
