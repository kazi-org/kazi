defmodule Kazi.Harness.Conformance do
  @moduledoc """
  The uniform **profile conformance harness** (T14.1, ADR-0022): the single
  ExUnit helper every NEW `Kazi.Harness.Profile` (Codex, Antigravity, claw, …
  in later tasks) reuses to prove it meets the onboarding contract.

  ADR-0016 made a harness DATA — a profile is just `{id, command, build_args,
  parse, supported_opts}`. ADR-0022 then named the two things a first-class
  profile must get right, and both are testable WITHOUT the real vendor binary:

    1. **argv** — `build_args(prompt, opts)` renders the exact non-interactive
       argv kazi will exec (everything after `command`); and
    2. **parse** — `parse(stdout)` extracts the ADDITIVE structured subset
       (`:result`, `:tokens`, `:cost`, `:cost_usd`, `:touched`, …) from a
       **golden transcript**: a recorded sample of the tool's REAL stdout,
       checked in as a fixture so the contract is pinned byte-for-byte and a
       vendor output-format regression is caught in CI (the live smoke, tagged
       `:<id>_live`, is the complementary catch with the real binary).

  This module is the golden-transcript counterpart to the existing stub-binary
  seam (`test/support/stub_*.sh`, `Kazi.Harness.ProfileRegistryTest`): the stub
  proves the live `System.cmd` boundary; the golden transcript proves the pure
  `parse` against frozen sample bytes the vendor actually emitted — no subprocess
  needed, so a future profile's parse test stays hermetic and deterministic.

  ## API

  `assert_profile_conformance/2` takes the profile (or its registry id) and a
  keyword list describing one conformance case:

      assert_profile_conformance(:opencode,
        prompt: "fix the failing test",
        opts: [model: "dgx/qwen3.6"],
        expected_argv: ~w(run fix\\ the\\ failing\\ test --format json --model dgx/qwen3.6),
        transcript: "harness/opencode_run.jsonl",
        expected_parse: %{result: "…", tokens: 1400, cost_usd: 0.0042}
      )

  Keys:

    * `:prompt` (required) — the prompt threaded to `build_args`.
    * `:opts` (default `[]`) — the opts threaded to `build_args`.
    * `:expected_argv` (required) — the argv `build_args` must render exactly.
    * `:transcript` (required) — the golden-transcript fixture. Either a path
      RELATIVE to `test/fixtures/` (e.g. `"harness/claude_envelope.json"`) or
      raw transcript bytes when `inline_transcript: true`.
    * `:expected_parse` (required) — a map of the fields `parse` must extract.
      Asserted as a SUBSET (parse is additive): every key/value in
      `expected_parse` must be present and equal, and no UNEXPECTED structured
      key may appear (so a profile cannot silently start emitting a field the
      golden case did not vet). Pass an empty map to assert "nothing structured".
    * `:inline_transcript` (default `false`) — treat `:transcript` as literal
      bytes rather than a fixture path (handy for tiny degenerate cases).

  Returns the parsed map so a caller can make additional bespoke assertions.

  `read_transcript/1` exposes the fixture loader for a test that wants the raw
  bytes (e.g. to run several `expected_parse` slices off one recording).
  """

  import ExUnit.Assertions

  alias Kazi.Harness.{Profile, Registry}

  @fixtures_root Path.expand("../fixtures", __DIR__)

  @doc """
  Asserts that `profile` conforms for one recorded case: its `build_args`
  renders `expected_argv` and its `parse` extracts `expected_parse` from the
  golden transcript. See the module doc for the option shape. Returns the parsed
  map.
  """
  @spec assert_profile_conformance(Profile.t() | atom(), keyword()) :: map()
  def assert_profile_conformance(profile_or_id, opts) when is_list(opts) do
    profile = resolve_profile(profile_or_id)

    prompt = fetch_opt!(opts, :prompt)
    build_opts = Keyword.get(opts, :opts, [])
    expected_argv = fetch_opt!(opts, :expected_argv)
    expected_parse = fetch_opt!(opts, :expected_parse)
    transcript = load_transcript(opts)

    assert_argv(profile, prompt, build_opts, expected_argv)
    assert_parse(profile, transcript, expected_parse)
  end

  @doc """
  Reads a golden-transcript fixture by its path relative to `test/fixtures/`.
  Raises a clear error if the fixture is missing so a typo'd path fails loudly.
  """
  @spec read_transcript(String.t()) :: String.t()
  def read_transcript(relative_path) when is_binary(relative_path) do
    path = Path.join(@fixtures_root, relative_path)

    case File.read(path) do
      {:ok, bytes} ->
        bytes

      {:error, reason} ->
        flunk(
          "golden transcript fixture not found at #{path} " <>
            "(#{:file.format_error(reason)}); store it under test/fixtures/"
        )
    end
  end

  # --- internals -------------------------------------------------------------

  defp resolve_profile(%Profile{} = profile), do: profile
  defp resolve_profile(id) when is_atom(id), do: Registry.fetch!(id)

  defp assert_argv(profile, prompt, build_opts, expected_argv) do
    rendered = Profile.build_args(profile, prompt, build_opts)

    assert rendered == expected_argv,
           "argv mismatch for profile #{inspect(profile.id)} " <>
             "(opts=#{inspect(build_opts)}):\n  expected: #{inspect(expected_argv)}\n" <>
             "  rendered: #{inspect(rendered)}"
  end

  defp assert_parse(profile, transcript, expected_parse) do
    parsed = Profile.parse(profile, transcript)

    # parse is ADDITIVE: every expected field must be present and equal...
    for {key, value} <- expected_parse do
      assert Map.has_key?(parsed, key),
             "profile #{inspect(profile.id)} parse omitted expected field #{inspect(key)} " <>
               "from the golden transcript; got: #{inspect(parsed)}"

      assert Map.fetch!(parsed, key) == value,
             "profile #{inspect(profile.id)} parse field #{inspect(key)} mismatch:\n" <>
               "  expected: #{inspect(value)}\n  actual:   #{inspect(Map.fetch!(parsed, key))}"
    end

    # ...and no UNVETTED structured key may sneak in beyond what the case declared.
    unexpected = Map.drop(parsed, Map.keys(expected_parse))

    assert unexpected == %{},
           "profile #{inspect(profile.id)} parse produced unexpected structured fields " <>
             "not vetted by this conformance case: #{inspect(unexpected)}"

    parsed
  end

  defp load_transcript(opts) do
    transcript = fetch_opt!(opts, :transcript)

    if Keyword.get(opts, :inline_transcript, false) do
      transcript
    else
      read_transcript(transcript)
    end
  end

  defp fetch_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "assert_profile_conformance requires #{inspect(key)}"
    end
  end
end
