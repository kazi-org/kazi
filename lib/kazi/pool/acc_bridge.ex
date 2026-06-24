defmodule Kazi.Pool.AccBridge do
  @moduledoc """
  The `acc:` → predicates bridge (T20.1, ADR-0026 L1).

  ADR-0026 integrates kazi UNDER each `/apply --pool` session: a pool session
  converts its plan task's `acc:` line (the acceptance-criteria text in a
  `docs/plan.md` WBS task) into kazi predicates and supplies them via
  `kazi propose --json --predicates <json>` (caller-drafts, ADR-0023). kazi then
  applies the deterministic floor, persists, and gates the merge on convergence —
  spawning NO inner model. This module is the thin, deterministic, hermetic helper
  that does the FIRST half: `acc:` text → a caller-drafts predicates payload.

  ## What it does

  `acc_to_predicates/1` takes the raw acceptance text (everything AFTER `acc:` in
  a WBS task) and returns a JSON-able map of the shape `propose --json
  --predicates` accepts:

      %{
        "name" => "<derived name>",
        "predicates" => [
          %{"id" => "...", "provider" => "...", "description" => "...",
            "config" => %{...}}
        ]
      }

  The acceptance text is split on `;` (the clause separator real WBS `acc:` lines
  use) and each clause is CLASSIFIED to a provider kind:

    * **test_runner** — a clause about tests passing or a named test command
      ("ExUnit ...", "mix test", "`mix format` clean", "tests pass",
      "`--warnings-as-errors` clean"). When a concrete command is recognisable
      (`mix test`, `mix format --check-formatted`, `npx playwright test`) it is
      emitted as the predicate's `config` (`cmd`/`args`); otherwise the clause is
      a DESCRIBED `test_runner` predicate with NO command — a best-effort marker
      the session/operator fills in, never an invented one.
    * **http_probe** — a clause about an endpoint returning a status
      ("the endpoint returns 200", "GET /healthz returns 200"). The path and the
      status are extracted into `config` when present; an unspecified status is
      left out (no invented specifics).
    * **prod_log** — a clause about a production/runtime log signal
      ("a prod log line appears", "the live predicate passes").

  A clause that matches none of these is emitted as a best-effort DESCRIBED
  `test_runner` predicate carrying the clause text — so the acceptance criterion
  is not silently dropped, but no unverifiable specifics are fabricated. The
  caller (and kazi's clarify floor) surface the gap.

  ## Determinism + hermeticity

  Pure parsing only: the same `acc:` input always yields the same payload, ids are
  derived deterministically from clause position + a short content digest, and the
  function does NO I/O (no network, no clock, no filesystem) beyond reading its
  argument. This is what lets a pooled session pipe `acc:` straight into
  `kazi propose --json --predicates` and gate its own merge on convergence.

  ## Usage from a pool session

  See `docs/acc-predicates-bridge.md` for the copy-pasteable procedure, and
  `priv/scripts/acc_to_predicates.exs` for the runner that prints the payload:

      mix run priv/scripts/acc_to_predicates.exs "ExUnit green; \\`mix format\\` clean" \\
        | kazi propose --json --predicates -
  """

  @typedoc "The raw acceptance text (everything after `acc:` in a WBS task)."
  @type acc :: String.t()

  @typedoc """
  A JSON-able caller-drafts proposal payload: `propose --json --predicates`
  accepts this object directly (or its JSON encoding).
  """
  @type payload :: %{required(String.t()) => term()}

  @doc """
  Converts an `acc:` acceptance line into a caller-drafts predicates payload.

  Pure, total, deterministic, and hermetic — same input, same output; no I/O. The
  returned map is JSON-encodable and ready for `kazi propose --json --predicates`.
  An `acc` that yields no clause (blank, or only separators) produces a single
  best-effort `test_runner` predicate describing "acceptance criteria are met", so
  the payload is never empty (an empty predicates list is refused downstream).

  ## Examples

      iex> payload = Kazi.Pool.AccBridge.acc_to_predicates("ExUnit green; the endpoint returns 200")
      iex> Enum.map(payload["predicates"], & &1["provider"])
      ["test_runner", "http_probe"]

      iex> p = Kazi.Pool.AccBridge.acc_to_predicates("`mix format` clean")
      iex> hd(p["predicates"])["config"]
      %{"cmd" => "mix", "args" => ["format", "--check-formatted"]}
  """
  @spec acc_to_predicates(acc()) :: payload()
  def acc_to_predicates(acc) when is_binary(acc) do
    predicates =
      acc
      |> split_clauses()
      |> Enum.with_index()
      |> Enum.map(fn {clause, index} -> build_predicate(clause, index) end)
      |> ensure_nonempty()

    %{
      "name" => derive_name(acc),
      "predicates" => predicates
    }
  end

  # --- clause splitting -------------------------------------------------------

  # Real WBS `acc:` lines separate criteria with `;`. Split on it, trim each
  # clause, and drop blanks. Deterministic and order-preserving.
  @spec split_clauses(acc()) :: [String.t()]
  defp split_clauses(acc) do
    acc
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # A blank/clause-less acc still yields one predicate, so the payload is never
  # the empty list `propose` refuses.
  defp ensure_nonempty([]) do
    [
      %{
        "id" => "acc-1",
        "provider" => "test_runner",
        "description" => "acceptance criteria are met",
        "config" => %{}
      }
    ]
  end

  defp ensure_nonempty(predicates), do: predicates

  # --- per-clause classification ---------------------------------------------

  # Classify a clause to a provider kind and build the predicate. The order of the
  # cond is the precedence: an http-status clause wins over a generic test clause
  # so "the endpoint returns 200" maps to http_probe, not test_runner.
  @spec build_predicate(String.t(), non_neg_integer()) :: map()
  defp build_predicate(clause, index) do
    id = clause_id(clause, index)

    cond do
      http_status_clause?(clause) -> http_probe_predicate(id, clause)
      prod_log_clause?(clause) -> prod_log_predicate(id, clause)
      test_clause?(clause) -> test_runner_predicate(id, clause)
      true -> described_predicate(id, clause)
    end
  end

  # A stable, content-derived id: the clause position plus a short digest of the
  # normalised clause text, so the same acc yields the same ids and two clauses
  # never collide. Deterministic (no randomness, no clock).
  defp clause_id(clause, index) do
    digest =
      clause
      |> String.downcase()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 6)

    "acc-#{index + 1}-#{digest}"
  end

  # --- test_runner ------------------------------------------------------------

  # A clause is a "tests pass" criterion when it names a test runner / formatter /
  # build check, or says tests pass/are green. The widest net of the three so a
  # generic green-tests clause still becomes a checkable predicate.
  defp test_clause?(clause) do
    down = String.downcase(clause)

    Regex.match?(
      ~r/\bexunit\b|\bmix test\b|\bmix format\b|\bnpx playwright\b|\bplaywright\b|warnings-as-errors|\btests?\b.*\b(pass|passes|passing|green)\b|\bgreen\b|\bformat\b.*\bclean\b|--check-formatted/,
      down
    )
  end

  # Build a test_runner predicate. A recognisable concrete command (mix test, mix
  # format --check-formatted, npx playwright test) is emitted as config; otherwise
  # the predicate is DESCRIBED with no command — a best-effort marker the operator
  # fills in, never an invented one.
  defp test_runner_predicate(id, clause) do
    base = %{
      "id" => id,
      "provider" => "test_runner",
      "description" => clause
    }

    case recognised_command(clause) do
      nil -> Map.put(base, "config", %{})
      {cmd, args} -> Map.put(base, "config", %{"cmd" => cmd, "args" => args})
    end
  end

  # Map a clause to a concrete command ONLY when it is unambiguous. We never
  # fabricate a command for a vague "tests pass" clause — that becomes a described
  # predicate the operator completes.
  defp recognised_command(clause) do
    down = String.downcase(clause)

    cond do
      Regex.match?(~r/--check-formatted|\bmix format\b/, down) ->
        {"mix", ["format", "--check-formatted"]}

      Regex.match?(~r/warnings-as-errors/, down) ->
        {"mix", ["compile", "--warnings-as-errors"]}

      Regex.match?(~r/\bnpx playwright\b|\bplaywright test\b/, down) ->
        {"npx", ["playwright", "test"]}

      Regex.match?(~r/\bmix test\b|\bexunit\b/, down) ->
        {"mix", ["test"]}

      true ->
        nil
    end
  end

  # --- http_probe -------------------------------------------------------------

  # A clause about an endpoint/route/URL returning a status code. Requires both an
  # endpoint signal AND a status verb so a generic "returns the list" clause is not
  # mis-mapped.
  defp http_status_clause?(clause) do
    down = String.downcase(clause)

    Regex.match?(~r/\bendpoint\b|\broute\b|\bGET\b|\bPOST\b|https?:\/\//i, clause) and
      Regex.match?(~r/\breturns?\b|\bresponds?\b|\bstatus\b/, down) and
      Regex.match?(~r/\b[1-5][0-9][0-9]\b/, clause)
  end

  # Build an http_probe predicate, extracting the path/URL and the status into
  # config when present. A status that is not pinned is left OUT (no invented
  # specifics); the clarify floor / operator supplies the URL when only a path is
  # known.
  defp http_probe_predicate(id, clause) do
    config =
      %{}
      |> maybe_put_url(extract_url(clause))
      |> maybe_put_status(extract_status(clause))

    %{
      "id" => id,
      "provider" => "http_probe",
      "description" => clause,
      "config" => config
    }
  end

  # A full URL wins; otherwise a leading path (e.g. /healthz) is recorded as a
  # relative `path` the operator resolves against the deploy target. We do NOT
  # invent a host.
  defp extract_url(clause) do
    cond do
      match = Regex.run(~r/https?:\/\/[^\s,;"']+/, clause) ->
        {:url, hd(match)}

      match = Regex.run(~r/(?<![\w])(\/[a-zA-Z0-9][\w\/\-.]*)/, clause) ->
        {:path, hd(tl(match))}

      true ->
        nil
    end
  end

  defp extract_status(clause) do
    case Regex.run(~r/\b([1-5][0-9][0-9])\b/, clause) do
      [_, status] -> String.to_integer(status)
      _ -> nil
    end
  end

  defp maybe_put_url(config, nil), do: config
  defp maybe_put_url(config, {:url, url}), do: Map.put(config, "url", url)
  defp maybe_put_url(config, {:path, path}), do: Map.put(config, "path", path)

  defp maybe_put_status(config, nil), do: config
  defp maybe_put_status(config, status), do: Map.put(config, "expect_status", status)

  # --- prod_log ---------------------------------------------------------------

  # A clause about a production/runtime log signal or a "live predicate passes".
  defp prod_log_clause?(clause) do
    down = String.downcase(clause)

    Regex.match?(
      ~r/\bprod log\b|\bproduction log\b|\blog line\b|\blive predicate\b|\bruntime signal\b/,
      down
    )
  end

  defp prod_log_predicate(id, clause) do
    %{
      "id" => id,
      "provider" => "prod_log",
      "description" => clause,
      "config" => %{}
    }
  end

  # --- best-effort fallback ---------------------------------------------------

  # A clause that matches no mechanical mapping is kept as a DESCRIBED test_runner
  # predicate with no command — the criterion is preserved (never silently
  # dropped) but no unverifiable specifics are fabricated. The operator / clarify
  # floor fills in the check.
  defp described_predicate(id, clause) do
    %{
      "id" => id,
      "provider" => "test_runner",
      "description" => clause,
      "config" => %{}
    }
  end

  # --- name derivation --------------------------------------------------------

  # A short, deterministic goal name from the first clause (or a default). Bounded
  # so a long clause does not become an unwieldy name.
  defp derive_name(acc) do
    case split_clauses(acc) do
      [first | _] -> first |> strip_backticks() |> truncate(72)
      [] -> "acceptance criteria"
    end
  end

  defp strip_backticks(text), do: String.replace(text, "`", "")

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max - 1) <> "…"
    else
      text
    end
  end
end
