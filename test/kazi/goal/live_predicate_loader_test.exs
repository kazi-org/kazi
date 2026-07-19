defmodule Kazi.Goal.LivePredicateLoaderTest do
  @moduledoc """
  T48.1 (ADR-0058): the loader REQUIRES a non-empty `url` on the two live
  predicate kinds (`http_probe`, `browser`) so a missing/blank url fails
  loudly at goal-load, naming the predicate and the key, instead of silently
  wedging the loop at OBSERVATION time.

  Motivation: a real production run burned 40 iterations against a live
  `http_probe` predicate that errored `missing_url` on every observation
  (a config error knowable at goal-load) before `max_iterations` finally
  tripped it as a mislabeled `over_budget`. Neither provider
  (`Kazi.Providers.HttpProbe`, `Kazi.Providers.Browser`) resolves any other
  key into a url at dispatch time -- `url` is the ONLY key either ever reads
  -- so this is checked here, once, for both kinds.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(provider, predicate_toml) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => provider}, predicate_toml)]
    })
  end

  describe "http_probe" do
    test "a missing url is a load error naming the predicate and the key" do
      assert {:error, msg} = load("http_probe", %{"expect_status" => 200})
      assert msg =~ ~s(http_probe predicate "p")
      assert msg =~ ~s(missing required key "url")
    end

    test "a blank url is a load error" do
      assert {:error, msg} = load("http_probe", %{"url" => ""})
      assert msg =~ ~s(missing required key "url")
    end

    test "a non-string url is a load error" do
      assert {:error, msg} = load("http_probe", %{"url" => 123})
      assert msg =~ ~s(missing required key "url")
    end

    # The dead config this guards against: `path` is not read by
    # Kazi.Providers.HttpProbe.fetch_url/1 -- only `url` is -- so a predicate
    # authored with `path` alone must NOT satisfy this check (it would silently
    # wedge exactly as the motivating production run did).
    test "a relative path with no url does not satisfy the check" do
      assert {:error, msg} = load("http_probe", %{"path" => "/healthz"})
      assert msg =~ ~s(missing required key "url")
    end

    test "a predicate with a non-empty url loads unchanged" do
      assert {:ok, %Goal{predicates: [%Predicate{kind: :http_probe, config: config}]}} =
               load("http_probe", %{
                 "url" => "https://example.test/healthz",
                 "expect_status" => 200,
                 "expect_body" => "ok"
               })

      assert config == %{
               url: "https://example.test/healthz",
               expect_status: 200,
               expect_body: "ok"
             }
    end
  end

  describe "browser" do
    test "a missing url is a load error naming the predicate and the key" do
      assert {:error, msg} = load("browser", %{})
      assert msg =~ ~s(browser predicate "p")
      assert msg =~ ~s(missing required key "url")
    end

    test "a blank url is a load error" do
      assert {:error, msg} = load("browser", %{"url" => ""})
      assert msg =~ ~s(missing required key "url")
    end

    test "a predicate with a non-empty url loads unchanged" do
      assert {:ok, %Goal{predicates: [%Predicate{kind: :browser, config: config}]}} =
               load("browser", %{"url" => "https://app.example.test/"})

      assert config == %{url: "https://app.example.test/"}
    end
  end

  describe "every shipped example loads under the new check" do
    @examples_dir Path.join([File.cwd!(), "priv", "examples"])

    for path <- Path.wildcard(Path.join(@examples_dir, "*.toml")) do
      @path path

      test "#{Path.basename(path)}: every http_probe/browser predicate carries a url" do
        assert {:ok, %Goal{predicates: predicates}} = Loader.load(@path)

        for %Predicate{kind: kind, id: id, config: config} <- predicates,
            kind in [:http_probe, :browser] do
          url = config[:url]

          assert is_binary(url) and url != "",
                 "#{Path.basename(@path)} predicate #{inspect(id)}: #{kind} requires a non-empty url"
        end
      end
    end
  end
end
