defmodule Kazi.RedactionTest do
  use ExUnit.Case, async: true

  alias Kazi.Redaction

  doctest Kazi.Redaction

  describe "well-known token formats" do
    test "AWS access key id" do
      assert Redaction.redact("key=AKIAIOSFODNN7EXAMPLE") == "key=[REDACTED]"
    end

    test "GitHub token" do
      secret = "ghp_" <> String.duplicate("a", 36)
      assert Redaction.redact("token #{secret} end") == "token [REDACTED] end"
    end

    test "OpenAI/Anthropic style key" do
      assert Redaction.redact("sk-ant-" <> String.duplicate("X", 24)) == "[REDACTED]"
    end

    test "Slack token" do
      assert Redaction.redact("xoxb-123456789012-abcdefABCDEF") == "[REDACTED]"
    end

    test "Google API key" do
      assert Redaction.redact("AIza" <> String.duplicate("a", 35)) == "[REDACTED]"
    end
  end

  describe "structural secrets" do
    test "JWT" do
      jwt = "eyJhbGciOi.eyJzdWIiOi.SflKxwRJSM"
      assert Redaction.redact("auth=#{jwt}") =~ "[REDACTED]"
      refute Redaction.redact("auth=#{jwt}") =~ "eyJ"
    end

    test "connection-string password (keeps user + host)" do
      assert Redaction.redact("postgres://app:s3cr3t@db:5432/prod") ==
               "postgres://app:[REDACTED]@db:5432/prod"
    end

    test "Bearer header (keeps the scheme)" do
      assert Redaction.redact("Authorization: Bearer abc.def-ghi123") ==
               "Authorization: Bearer [REDACTED]"
    end

    test "PEM private key block" do
      pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAK\nzzz\n-----END RSA PRIVATE KEY-----"
      out = Redaction.redact("before\n#{pem}\nafter")
      assert out == "before\n[REDACTED]\nafter"
    end
  end

  describe "named secrets (value redacted, key kept)" do
    test "password= " do
      assert Redaction.redact("password=hunter2") == "password=[REDACTED]"
    end

    test "api_key: with quotes preserves the quotes" do
      assert Redaction.redact(~s(api_key: "abc123xyz")) == ~s(api_key: "[REDACTED]")
    end

    test "client_secret in a config dump" do
      assert Redaction.redact("client_secret=AbC-9_8") == "client_secret=[REDACTED]"
    end
  end

  describe "conservative on ordinary output (no false positives)" do
    test "normal test output is unchanged" do
      out = "1 test, 1 failure\nexpected 200 got 404\nlib/foo.ex:42"
      assert Redaction.redact(out) == out
    end

    test "the word token without a delimiter is untouched" do
      assert Redaction.redact("the auth token then issues a cookie") ==
               "the auth token then issues a cookie"
    end

    test "empty string" do
      assert Redaction.redact("") == ""
    end
  end

  describe "idempotence" do
    test "redacting twice equals redacting once" do
      input = "password=hunter2 and key=AKIAIOSFODNN7EXAMPLE"
      once = Redaction.redact(input)
      assert Redaction.redact(once) == once
    end
  end
end
