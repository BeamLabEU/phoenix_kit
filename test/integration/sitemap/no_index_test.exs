defmodule PhoenixKit.Integration.Sitemap.NoIndexTest do
  @moduledoc """
  Pins the contract that the sitemap generator honors the Crawlers module's global
  `noindex` directive.

  When `crawlers_no_index` is active the site is asking search engines not to index
  it, so `Generator.generate_all/1` must publish an empty (but valid) `<urlset>`
  instead of advertising crawlable URLs — regardless of what the individual
  sources would otherwise emit.

  `crawlers_sitemap_exempt_from_no_index` carves the sitemap's *content* back out
  of that directive without touching the robots meta/`no_index_enabled?/0` itself:
  an operator can keep the site marked noindex while still publishing a full
  sitemap (e.g. to verify the feed independently of the indexing block). Default
  is `false`, so an install that has never heard of this flag gets exactly
  today's behavior — the sitemap still blanks with `crawlers_no_index`.
  """
  use PhoenixKit.DataCase, async: false

  require Logger

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Settings

  @base_url "https://example.test"

  setup do
    # Sitemap generation needs the module enabled and a base URL.
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", true)
    {:ok, _} = Settings.update_setting("site_url", @base_url)
    :ok
  end

  describe "generate_all/1 with crawlers_no_index active" do
    test "publishes an empty urlset with zero URLs when sitemap is not exempt" do
      {:ok, _} = Settings.update_boolean_setting("crawlers_no_index", true)
      {:ok, _} = Settings.update_boolean_setting("crawlers_sitemap_exempt_from_no_index", false)

      assert {:ok, %{index_xml: xml, total_urls: 0, modules: [], reason: :no_index}} =
               Generator.generate_all(base_url: @base_url)

      # Valid, empty urlset — no crawlable entries advertised.
      assert xml =~ "<urlset"
      assert xml =~ "</urlset>"
      refute xml =~ "<url>"
      refute xml =~ "<loc>"
    end

    test "still generates a full sitemap when the sitemap is exempt" do
      {:ok, _} = Settings.update_boolean_setting("crawlers_no_index", true)
      {:ok, _} = Settings.update_boolean_setting("crawlers_sitemap_exempt_from_no_index", true)

      # The noindex short-circuit must NOT be taken: generation runs normally,
      # exactly as if crawlers_no_index were off, even though it is on. Assert
      # actual content (not just "an integer count"), since 0 is an integer
      # too and would let this test pass against the unfixed generator.
      assert {:ok, %{index_xml: xml, total_urls: total}} =
               Generator.generate_all(base_url: @base_url)

      assert total >= 1
      assert xml =~ "<loc>"
    end

    test "Sitemap.regenerate/0 says why the sitemap is empty, in the result and the log" do
      {:ok, _} = Settings.update_boolean_setting("crawlers_no_index", true)
      {:ok, _} = Settings.update_boolean_setting("crawlers_sitemap_exempt_from_no_index", false)

      # The suite logs at :warning (config/test.exs); the line is :info.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:ok, %{total_urls: 0, reason: :no_index}} = Sitemap.regenerate()
        end)

      assert log =~ "noindex"
    end
  end

  describe "generate_all/1 with crawlers_no_index disabled" do
    test "does not force an empty sitemap when sitemap exemption is off" do
      {:ok, _} = Settings.update_boolean_setting("crawlers_no_index", false)
      {:ok, _} = Settings.update_boolean_setting("crawlers_sitemap_exempt_from_no_index", false)

      # The exact URL count depends on seeded content/routes; we only assert the
      # noindex short-circuit is NOT taken (generation runs normally).
      assert {:ok, %{total_urls: total} = result} = Generator.generate_all(base_url: @base_url)
      assert is_integer(total)
      refute Map.has_key?(result, :reason)
    end

    test "does not force an empty sitemap when sitemap exemption is on" do
      {:ok, _} = Settings.update_boolean_setting("crawlers_no_index", false)
      {:ok, _} = Settings.update_boolean_setting("crawlers_sitemap_exempt_from_no_index", true)

      # Exemption is meaningless when noindex is already off — same as above.
      assert {:ok, %{total_urls: total}} = Generator.generate_all(base_url: @base_url)
      assert is_integer(total)
    end
  end
end
