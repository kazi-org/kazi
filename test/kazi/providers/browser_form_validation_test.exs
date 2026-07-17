defmodule Kazi.Providers.BrowserFormValidationTest do
  @moduledoc """
  T43.4 (UC-056): the `form_validation` composite assertion and the four DOM-state
  assertions (`attr`, `count`, `enabled`, `field_value`). Tier 2, hermetic — the
  provider's real encode → spawn → parse → map-to-contract path runs against the
  shared `stub_playwright.sh`, which returns the canned runner verdict a real
  Playwright run would produce (CI has no browser). This pins that the PROVIDER
  surfaces each verdict — pass/fail plus the expected-vs-found evidence — exactly
  as the runner reports it. The runner's own DOM logic is exercised end-to-end in
  the Tier-4 live dogfood (T43.6); the loader-vocabulary side is pinned in
  `Kazi.Goal.LoaderBrowserAssertionParityTest` and the key-validation tests below.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Browser

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_formval_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # Feed the provider a canned runner verdict carrying `records` as its assertions,
  # and one authored `assertions` entry so the config is well-formed.
  defp evaluate(workspace, records, assertions) do
    verdict =
      Jason.encode!(%{
        status: if(Enum.all?(records, & &1.ok), do: "pass", else: "fail"),
        url: "https://example.test/signup",
        assertions: records,
        screenshot: nil,
        error: nil
      })

    config = %{
      url: "https://example.test/signup",
      cmd: @stub,
      args: [],
      env: [{"STUB_JSON", verdict}],
      assertions: assertions
    }

    Browser.evaluate(Predicate.new(:ui, :browser, config: config), %{workspace: workspace})
  end

  describe "form_validation — the three sub-checks" do
    test "a passing form record passes, with each sub-check recorded true", %{workspace: ws} do
      record = %{
        type: "form_validation",
        ok: true,
        expected: "all requested form checks hold",
        found: %{
          error_shown: true,
          submit_disabled_until_valid: true,
          submission_persisted: true
        }
      }

      result = evaluate(ws, [record], [%{type: "form_validation", submit_selector: "button"}])

      assert %PredicateResult{status: :pass} = result
      [ev] = result.evidence.assertions
      assert ev["found"]["error_shown"] == true
      assert ev["found"]["submission_persisted"] == true
    end

    for {sub_check, label} <- [
          {"error_shown", "invalid input does not surface the expected error"},
          {"submit_disabled_until_valid", "submit is enabled while the form is invalid"},
          {"submission_persisted", "a valid submission does not persist"}
        ] do
      test "fails when #{sub_check} is false (#{label}), naming which broke", %{workspace: ws} do
        # All three start true; flip exactly one so the failure is attributable.
        found =
          %{
            "error_shown" => true,
            "submit_disabled_until_valid" => true,
            "submission_persisted" => true
          }
          |> Map.put(unquote(sub_check), false)

        record = %{
          type: "form_validation",
          ok: false,
          expected: "all requested form checks hold",
          found: found
        }

        result = evaluate(ws, [record], [%{type: "form_validation", submit_selector: "button"}])

        assert %PredicateResult{status: :fail} = result
        [ev] = result.evidence.assertions

        # The evidence names WHICH sub-check failed — the whole point of the
        # composite reporting each rather than a single boolean.
        assert ev["found"][unquote(sub_check)] == false,
               "the failing sub-check #{unquote(sub_check)} must be surfaced as false"

        # The other two stayed true, so the fail is unambiguously attributable.
        others = Map.delete(ev["found"], unquote(sub_check))
        assert Enum.all?(Map.values(others), &(&1 == true))
      end
    end

    test "a sub-check the goal omitted is null, not counted against the verdict", %{workspace: ws} do
      # Only the error sub-check was requested; the other two are null (skipped).
      record = %{
        type: "form_validation",
        ok: true,
        expected: "all requested form checks hold",
        found: %{
          error_shown: true,
          submit_disabled_until_valid: nil,
          submission_persisted: nil
        }
      }

      result = evaluate(ws, [record], [%{type: "form_validation", error_selector: "#err"}])

      assert %PredicateResult{status: :pass} = result
      [ev] = result.evidence.assertions
      assert ev["found"]["submit_disabled_until_valid"] == nil
    end
  end

  describe "DOM-state assertions on stub records" do
    for {type, extra, pass_found, fail_found} <- [
          {"attr", %{name: "aria-invalid", expected: "true"}, "true", "false"},
          {"count", %{expected: 3}, 3, 5},
          {"enabled", %{expected: false}, false, true},
          {"field_value", %{expected: "a@b.com"}, "a@b.com", ""}
        ] do
      test "#{type} passes when the record holds", %{workspace: ws} do
        record = %{
          type: unquote(type),
          selector: "#el",
          ok: true,
          expected: unquote(Macro.escape(pass_found)),
          found: unquote(Macro.escape(pass_found))
        }

        assertion =
          Map.merge(%{type: unquote(type), selector: "#el"}, unquote(Macro.escape(extra)))

        result = evaluate(ws, [record], [assertion])

        assert %PredicateResult{status: :pass} = result
      end

      test "#{type} fails with expected-vs-found evidence when it violates", %{workspace: ws} do
        record = %{
          type: unquote(type),
          selector: "#el",
          ok: false,
          expected: unquote(Macro.escape(pass_found)),
          found: unquote(Macro.escape(fail_found))
        }

        assertion =
          Map.merge(%{type: unquote(type), selector: "#el"}, unquote(Macro.escape(extra)))

        result = evaluate(ws, [record], [assertion])

        assert %PredicateResult{status: :fail} = result
        [ev] = result.evidence.assertions
        assert ev["expected"] == unquote(Macro.escape(pass_found))
        assert ev["found"] == unquote(Macro.escape(fail_found))
      end
    end
  end
end
