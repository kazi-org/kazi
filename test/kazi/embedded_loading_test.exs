defmodule Kazi.EmbeddedLoadingTest do
  # Pins issue #1006: a kazi run whose on-disk release payload disappears
  # mid-run (manual cleanup, disk pressure) crashed the BEAM on the next LAZY
  # module load ({io_lib_pretty,nofile} -> kernel terminated). The fix is
  # `mode: :embedded` in mix.exs's releases config, which loads every module
  # a release ships at BOOT instead of on first use -- eliminating the lazy
  # load entirely in the shape that crashed.
  #
  # `mix test` never boots a release (there is no embedded-mode boot to
  # observe here), so this test pins the OTHER half of the guarantee: the
  # exact stdlib error-path modules the incident hit (io_lib_pretty and its
  # neighbors) are loadable at all -- a moved/renamed/removed module in a
  # future OTP upgrade would silently reintroduce the crash class even with
  # `mode: :embedded` set, since embedded mode only preloads modules that
  # exist.
  use ExUnit.Case, async: true

  # The exact module the incident's crash trace named, plus its immediate
  # error-formatting neighbors -- the modules a crash report / Logger
  # formatter reaches for on the failure path itself.
  @critical_stdlib_modules [
    :io_lib_pretty,
    :io_lib_format,
    :logger_formatter
  ]

  test "mix.exs opts the kazi release into embedded module loading" do
    mix_exs = File.read!(Path.join(File.cwd!(), "mix.exs"))
    assert mix_exs =~ "mode: :embedded"
  end

  test "the critical stdlib error-path modules are loadable after boot" do
    Enum.each(@critical_stdlib_modules, fn mod ->
      assert {:module, ^mod} = :code.ensure_loaded(mod)
      assert :code.is_loaded(mod) != false
    end)
  end
end
