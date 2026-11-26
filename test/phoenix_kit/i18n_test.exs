defmodule PhoenixKit.I18nTest do
  @moduledoc """
  The host-facing view of the kit's languages: served URL segments, segment
  resolution, and the URL builders behind `localized_url/3`,
  `hreflang_links/2` and `language_links/2`. Languages are modelled with a
  primed settings cache (no database).
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.I18n
  alias PhoenixKit.Test.LanguageSettings

  @base "https://example.com"

  defp product_url(nil), do: "/products/42"
  defp product_url(segment), do: "/#{segment}/products/42"

  describe "multilingual, primary served with its segment" do
    setup do
      LanguageSettings.multilingual!(languages: ~w(en-US et ru))
    end

    test "enabled_locales/0 lists the URL segments in configured order" do
      assert I18n.enabled_locales() == ["en", "et", "ru"]
      refute I18n.prefixless_primary?()
    end

    test "languages carry the dialect, base, hreflang and primary flag" do
      [en, et, _ru] = I18n.languages()

      assert %{code: "en", locale: "en-US", base: "en", hreflang: "en", primary?: true} = en
      refute en.prefixless?
      assert %{code: "et", locale: "et", primary?: false, prefixless?: false} = et
      assert is_binary(et.native_name)
    end

    test "resolve_segment/1: served, another spelling, unknown" do
      assert {:ok, %{code: "et"}} = I18n.resolve_segment("et")
      assert {:redirect, %{code: "et"}} = I18n.resolve_segment("ET")
      assert {:redirect, %{code: "en"}} = I18n.resolve_segment("en-US")
      assert {:redirect, %{code: "en"}} = I18n.resolve_segment("en_us")
      assert I18n.resolve_segment("de") == :error
      assert I18n.resolve_segment("admin") == :error
      assert I18n.resolve_segment("products") == :error
    end

    test "localized_url/3 calls the host builder with the segment" do
      assert I18n.localized_url(nil, "et", url: &product_url/1) == "/et/products/42"
      assert I18n.localized_url(nil, "en", url: &product_url/1) == "/en/products/42"
      assert I18n.localized_url(nil, "ru-RU", url: &product_url/1) == "/ru/products/42"
    end

    test "localized_url/3 is nil for a language the site does not serve" do
      assert I18n.localized_url(nil, "de", url: &product_url/1) == nil
    end

    test "an arity-2 builder also gets the language map" do
      builder = fn segment, lang -> "/#{segment}/#{lang.locale}" end
      assert I18n.localized_url(nil, "et", url: builder) == "/et/et"
    end

    test "absolute: true puts a path on the base URL, leaves an absolute URL alone" do
      assert I18n.localized_url(nil, "et", url: &product_url/1, absolute: true, base_url: @base) ==
               "https://example.com/et/products/42"

      domain = fn segment -> "https://#{segment}.example.com/p" end

      assert I18n.localized_url(nil, "et", url: domain, absolute: true, base_url: @base) ==
               "https://et.example.com/p"
    end

    test "without a builder or strategy the kit refuses to guess" do
      assert_raise ArgumentError, ~r/how the host builds a localized URL/, fn ->
        I18n.localized_url(nil, "et")
      end

      assert_raise ArgumentError, fn -> I18n.language_links(nil, strategy: :guess) end
    end

    test "hreflang_links/2: one absolute link per language plus x-default" do
      assert I18n.hreflang_links(nil, url: &product_url/1, base_url: @base) == [
               %{hreflang: "en", href: "https://example.com/en/products/42"},
               %{hreflang: "et", href: "https://example.com/et/products/42"},
               %{hreflang: "ru", href: "https://example.com/ru/products/42"},
               %{hreflang: "x-default", href: "https://example.com/en/products/42"}
             ]

      refute Enum.any?(
               I18n.hreflang_links(nil, url: &product_url/1, base_url: @base, x_default: false),
               &(&1.hreflang == "x-default")
             )
    end

    test "strategy: :path replaces the leading locale segment of the current page" do
      conn = Plug.Test.conn(:get, "/et/products/42?tab=specs")
      conn = Plug.Conn.assign(conn, :current_locale, "et")

      assert I18n.localized_url(conn, "ru", strategy: :path) == "/ru/products/42?tab=specs"
      assert I18n.localized_url(conn, "en", strategy: :path) == "/en/products/42?tab=specs"
    end

    test "strategy: :query sets the locale parameter" do
      context = %{current_path: "/products?page=2"}

      assert I18n.localized_url(context, "et", strategy: :query) ==
               "/products?locale=et&page=2"

      assert I18n.localized_url(context, "et", strategy: :query, query_param: "lang") ==
               "/products?lang=et&page=2"
    end

    test "language_links/2 marks the current language from the context" do
      links = I18n.language_links(%{current_locale: "et"}, url: &product_url/1)

      assert Enum.map(links, &{&1.code, &1.url, &1.current?}) == [
               {"en", "/en/products/42", false},
               {"et", "/et/products/42", true},
               {"ru", "/ru/products/42", false}
             ]

      assert %{name: _, native_name: _, flag: _, hreflang: "et", primary?: false} =
               Enum.at(links, 1)

      refute Map.has_key?(hd(links), :prefixless?)
    end

    test "language_links/2: hide_current and an explicit current" do
      links = I18n.language_links(nil, url: &product_url/1, current: "ru", hide_current: true)
      assert Enum.map(links, & &1.code) == ["en", "et"]
    end

    test "the current language falls back to the primary" do
      assert %{code: "en"} = I18n.current_language(%{})
    end
  end

  describe "multilingual, primary served without a segment" do
    setup do
      LanguageSettings.multilingual!(languages: ~w(en-US et), no_prefix: true)
    end

    test "the primary is prefixless and its builder gets nil" do
      assert I18n.prefixless_primary?()
      assert %{code: "en", prefixless?: true} = I18n.primary_language()
      assert I18n.localized_url(nil, "en", url: &product_url/1) == "/products/42"
      assert I18n.localized_url(nil, "et", url: &product_url/1) == "/et/products/42"
    end

    test "x-default is the prefixless URL" do
      assert List.last(I18n.hreflang_links(nil, url: &product_url/1, base_url: @base)) ==
               %{hreflang: "x-default", href: "https://example.com/products/42"}
    end

    test "strategy :path and :query drop the segment / parameter for the primary" do
      assert I18n.localized_url(%{current_path: "/et/products"}, "en", strategy: :path) ==
               "/products"

      assert I18n.localized_url(%{current_path: "/products?locale=et"}, "en", strategy: :query) ==
               "/products"
    end

    test "a request path shaped as //host never becomes a link to another site" do
      for path <- ["/et//evil.com", "/et/\\evil.com", "/et///evil.com/x"],
          strategy <- [:path, :kit] do
        url = I18n.localized_url(%{current_path: path}, "en", strategy: strategy)
        assert String.starts_with?(url, "/"), inspect({path, strategy, url})
        refute String.starts_with?(url, "//"), inspect({path, strategy, url})
        refute String.starts_with?(url, "/\\"), inspect({path, strategy, url})

        [%{href: href} | _] =
          I18n.hreflang_links(%{current_path: path}, strategy: strategy, base_url: @base)

        assert String.starts_with?(href, @base <> "/"), inspect({path, strategy, href})
      end

      url = I18n.localized_url(%{current_path: "//evil.com/x?locale=et"}, "en", strategy: :query)
      refute String.starts_with?(url, "//")
    end
  end

  describe "sibling dialects" do
    setup do
      LanguageSettings.multilingual!(languages: ~w(en-US en-GB))
    end

    test "the sibling is served at its lowercase full code, hreflang in BCP 47 case" do
      assert I18n.enabled_locales() == ["en", "en-gb"]

      assert %{code: "en-gb", locale: "en-GB", hreflang: "en-GB"} =
               I18n.find_language("en-gb")

      assert {:redirect, %{code: "en-gb"}} = I18n.resolve_segment("en-GB")
    end
  end

  describe "single-language site" do
    setup do
      LanguageSettings.single_language!(languages: ~w(et))
    end

    test "only the primary is served, without a segment, and there is no alternate" do
      assert I18n.enabled_locales() == ["et"]
      assert %{code: "et", locale: "et", prefixless?: true} = I18n.primary_language()
      assert I18n.resolve_segment("en") == :error
      assert I18n.hreflang_links(nil, url: &product_url/1, base_url: @base) == []

      assert [%{code: "et", url: "/products/42", current?: true}] =
               I18n.language_links(nil, url: &product_url/1)
    end
  end
end
