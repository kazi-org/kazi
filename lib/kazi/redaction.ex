defmodule Kazi.Redaction do
  @moduledoc """
  Secret redaction for any text kazi projects OUT of the target workspace
  (T35.3, ADR-0009 amendment + ADR-0045).

  kazi captures raw evidence — test logs, compiler diagnostics, HTTP bodies,
  harness stderr — and routes it to two places that leave the workspace:

    * the **harness prompt** (`Kazi.Harness.Prompt`) handed to a third-party agent,
      and
    * the **context store** (`Kazi.ContextStore`) that indexes heavy artifacts for
      budget-fitted recall (ADR-0045).

  A credential that lands in captured output (a `DATABASE_URL` in a failing
  migration log, an `Authorization` header in a flaky HTTP test) would otherwise
  flow verbatim into a model prompt or an indexed store — "an un-redacted store is
  a credential store" (ADR-0045). This module is the **single, shared redactor**
  both paths pass text through, so they redact identically (the parity T35.3
  requires); there is exactly one pattern set to audit.

  `redact/1` is a pure, total function: it replaces high-confidence secret shapes
  with `#{inspect(__MODULE__)}.placeholder/0` and returns the rest unchanged. It is
  deliberately conservative about *generic* values (it keeps real failure output
  legible for the repair loop) but aggressive about *named* secrets and
  well-known token formats. It is a mitigation, not a guarantee: the durable rule
  is to keep credentials out of the workspace; this is the backstop for when they
  leak into output anyway.
  """

  @placeholder "[REDACTED]"

  @typedoc "The marker substituted for a redacted secret."
  @type placeholder :: String.t()

  # Each rule is `{regex, replacement}` where replacement is a `Regex.replace/3`
  # spec: a binary (with `\\N` backrefs) or a function of the captures. Applied in
  # order; earlier (structural) rules run before the generic key=value rule.
  @structural_rules [
    # PEM private-key blocks (any flavour). Greedy-but-bounded across newlines.
    {~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----/s,
     @placeholder},
    # JSON Web Tokens: header.payload.signature, all base64url.
    {~r/\beyJ[A-Za-z0-9_-]{6,}\.eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}/, @placeholder},
    # Credentials embedded in a connection URL: scheme://user:secret@host.
    {~r{\b([a-zA-Z][a-zA-Z0-9+.\-]*://[^:@\s/]+):([^@\s/]+)@}, "\\1:#{@placeholder}@"},
    # Authorization: Bearer/Basic <token>.
    {~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/-]+=*/, "\\1 #{@placeholder}"}
  ]

  # Well-known provider token formats — high-confidence, low false-positive.
  @token_rules [
    # AWS access key id.
    {~r/\bAKIA[0-9A-Z]{16}\b/, @placeholder},
    # GitHub tokens (ghp_/gho_/ghu_/ghs_/ghr_).
    {~r/\bgh[pousr]_[A-Za-z0-9]{36,}\b/, @placeholder},
    # Slack tokens.
    {~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/, @placeholder},
    # OpenAI / Anthropic style secret keys (sk-..., sk-ant-...).
    {~r/\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}\b/, @placeholder},
    # Google API keys.
    {~r/\bAIza[0-9A-Za-z_-]{35}\b/, @placeholder}
  ]

  # Generic NAMED secret: a credential-ish key followed by `:` or `=` and a value.
  # Only the VALUE is redacted; the key stays so the reader still sees WHAT was
  # present. Scoped to a curated key list to keep ordinary output legible.
  @named_secret_key ~r/(?i)\b(password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)(\s*[:=]\s*)(["']?)([^\s"']+)(["']?)/

  @doc """
  Redacts secrets in `text`, returning a string of the same shape with
  high-confidence secret values replaced by `placeholder/0`.

  Pure and total. Non-binary input is rejected at the guard; callers stringify
  first (the prompt and store paths both pass binaries).

  ## Examples

      iex> Kazi.Redaction.redact("export AWS_KEY=AKIAIOSFODNN7EXAMPLE done")
      "export AWS_KEY=[REDACTED] done"

      iex> Kazi.Redaction.redact("DATABASE_URL=postgres://app:s3cr3t@db:5432/prod")
      "DATABASE_URL=postgres://app:[REDACTED]@db:5432/prod"

      iex> Kazi.Redaction.redact("1 test, 1 failure")
      "1 test, 1 failure"
  """
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text
    |> apply_rules(@structural_rules)
    |> apply_rules(@token_rules)
    |> redact_named_secrets()
  end

  @doc "The marker substituted for a redacted secret."
  @spec placeholder() :: placeholder()
  def placeholder, do: @placeholder

  @spec apply_rules(String.t(), [{Regex.t(), term()}]) :: String.t()
  defp apply_rules(text, rules) do
    Enum.reduce(rules, text, fn {re, replacement}, acc ->
      Regex.replace(re, acc, replacement)
    end)
  end

  # Redact the VALUE after a named credential key, preserving the key, separator,
  # and any surrounding quotes so the structure stays readable.
  @spec redact_named_secrets(String.t()) :: String.t()
  defp redact_named_secrets(text) do
    Regex.replace(@named_secret_key, text, fn _full, key, sep, open_q, _value, close_q ->
      key <> sep <> open_q <> @placeholder <> close_q
    end)
  end
end
