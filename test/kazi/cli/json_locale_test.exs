defmodule Kazi.CLI.JsonLocaleTest do
  @moduledoc """
  T54.7 (#1076): `--json` output is valid JSON regardless of the caller's locale.

  Under a non-UTF-8 locale (`env -i`) the `:standard_io` device is in `latin1`
  mode, so `IO.puts(Jason.encode!(payload))` transcodes each non-ASCII codepoint
  (an em-dash, a snowman, an accented letter) to the literal 7-char string
  `\\x{2014}` -- which no strict JSON parser accepts. The fix escapes to ASCII at
  the ENCODER (`escape: :unicode_safe`, `\\uXXXX`), so the bytes are pure ASCII
  and identical on every device, WITHOUT mutating the process-global
  `:io.setopts` (which would fight the very `env -i` scenario).

  A latin1 output device is reproduced hermetically with
  `capture_io(encoding: :latin1, ...)` -- the same device condition a non-UTF-8
  locale creates, with no global state to restore. The `apply <missing> --json`
  path echoes its (here deliberately non-ASCII) goal-file path into the JSON
  error object, so it exercises a real routed `--json` write site end to end.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # An em-dash, a snowman, and an accented letter -- the acceptance payload.
  @unicode "em—dash ☃ café"

  test "a --json error is pure-ASCII, valid JSON, and lossless on a latin1 device" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "kazi-t547-#{@unicode}-#{System.unique_integer([:positive])}.toml"
      )

    out =
      capture_io([encoding: :latin1], fn ->
        assert Kazi.CLI.run(["apply", missing, "--workspace", "/tmp", "--json"]) == 1
      end)

    trimmed = String.trim(out)

    # Pure ASCII: no byte escaped the 7-bit range, so no device can mangle it.
    assert Enum.all?(String.to_charlist(trimmed), &(&1 < 128)),
           "expected pure-ASCII JSON, got non-ASCII bytes: #{inspect(trimmed)}"

    # The old-code failure mode -- the literal `\x{...}` transcode -- is absent.
    refute trimmed =~ "\\x{"

    # Valid JSON, and the non-ASCII path round-trips back LOSSLESS.
    assert {:ok, payload} = Jason.decode(trimmed)
    assert payload["error"] =~ missing
    assert payload["error"] =~ @unicode
    assert payload["schema_version"]
  end

  test "the same command on a unicode device is byte-identical (locale-independent)" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "kazi-t547u-#{@unicode}-#{System.unique_integer([:positive])}.toml"
      )

    latin1 =
      capture_io([encoding: :latin1], fn ->
        assert Kazi.CLI.run(["apply", missing, "--workspace", "/tmp", "--json"]) == 1
      end)

    unicode =
      capture_io([encoding: :unicode], fn ->
        assert Kazi.CLI.run(["apply", missing, "--workspace", "/tmp", "--json"]) == 1
      end)

    assert latin1 == unicode
  end
end
