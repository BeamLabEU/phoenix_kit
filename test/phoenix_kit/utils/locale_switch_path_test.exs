defmodule PhoenixKit.Utils.LocaleSwitchPathTest do
  @moduledoc """
  The language switcher's URL builder.

  Uses a primed settings cache to model configured languages without a database.

  Pins the reported break: from `/phoenix_kit/ja/admin`, switching to English
  produced `/phoenix_kit/en/ja/admin` — a path that routes nowhere. The switcher
  offered every *display* language while its URL builder only recognised the
  smaller *enabled* set, so a locale it had just put in the URL was not
  recognised on the way back out.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKit.Utils.Routes

  setup do
    if Application.get_env(:phoenix_kit, :test_repo_available, false) do
      :ok = Sandbox.checkout(PhoenixKit.Test.Repo)
    end

    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :settings})
    PhoenixKit.Cache.put(:settings, "languages_enabled", "true")
    PhoenixKit.Cache.put(:settings, "default_language_no_prefix", "false")

    languages =
      Enum.map(~w(en-US ja es-ES fr-FR de-DE), fn code ->
        %{"code" => code, "name" => code, "is_enabled" => true, "is_default" => code == "en-US"}
      end)

    PhoenixKit.Cache.put(:settings, "languages_config", %{"languages" => languages})
    :ok
  end

  describe "the reported sequence" do
    test "switching away from a locale-prefixed path does not stack prefixes" do
      assert Routes.locale_switch_path("/phoenix_kit/ja/admin", "en") ==
               "/phoenix_kit/en/admin"

      refute Routes.locale_switch_path("/phoenix_kit/ja/admin", "en") =~ "/en/ja/"
    end

    test "the first hop, from an unprefixed path, still works" do
      assert Routes.locale_switch_path("/phoenix_kit/admin", "ja") ==
               "/phoenix_kit/ja/admin"
    end

    test "swapping between two non-default locales replaces rather than appends" do
      assert Routes.locale_switch_path("/phoenix_kit/ja/admin", "es") ==
               "/phoenix_kit/es/admin"
    end
  end

  describe "repeated switching" do
    test "any number of hops leaves exactly one locale segment" do
      final =
        Enum.reduce(~w(ja es fr en ja de), "/phoenix_kit/admin", fn locale, path ->
          Routes.locale_switch_path(path, locale)
        end)

      assert final == "/phoenix_kit/de/admin"

      # The actual failure mode was accumulation, so count segments rather than
      # only comparing the final string.
      assert final |> String.split("/", trim: true) |> length() == 3
    end
  end

  describe "path shapes" do
    test "a deeper path keeps everything after the locale" do
      assert Routes.locale_switch_path("/phoenix_kit/ja/admin/users", "en") ==
               "/phoenix_kit/en/admin/users"
    end

    test "a path that is only a locale reduces cleanly" do
      assert Routes.locale_switch_path("/phoenix_kit/ja", "en") == "/phoenix_kit/en"
    end

    test "nil and empty paths do not raise" do
      assert is_binary(Routes.locale_switch_path(nil, "en"))
      assert is_binary(Routes.locale_switch_path("", "en"))
    end
  end

  describe "segments that are not locales" do
    test "a first segment the switcher could never emit is left alone" do
      # The shape-matching copy of this function would have eaten these: both
      # are short lowercase words that look like language codes.
      assert Routes.locale_switch_path("/phoenix_kit/admin/media", "ja") ==
               "/phoenix_kit/ja/admin/media"
    end

    test "the whole path survives when nothing is stripped" do
      switched = Routes.locale_switch_path("/phoenix_kit/admin/users", "ja")

      assert switched =~ "/admin/users"
    end
  end

  describe "preview languages are not URL segments" do
    test "an unconfigured language-shaped host segment is kept" do
      assert Routes.locale_switch_path("/phoenix_kit/nl/products", "ja") ==
               "/phoenix_kit/ja/nl/products"
    end

    test "turning languages off does not turn the preview defaults into locales" do
      PhoenixKit.Cache.put(:settings, "languages_enabled", "false")

      # A single-language site emits no locale segment at all, and `nl` is not
      # one of its locales either, so the host segment is kept.
      assert Routes.locale_switch_path("/phoenix_kit/nl/products", "en") ==
               "/phoenix_kit/nl/products"
    end

    test "a disabled language is kept unless explicitly identified as the current locale" do
      PhoenixKit.Cache.put(:settings, "languages_config", %{
        "languages" => [%{"code" => "nl", "name" => "Dutch", "is_enabled" => false}]
      })

      assert Routes.locale_switch_path("/phoenix_kit/nl/products", "en") ==
               "/phoenix_kit/en/nl/products"

      assert Routes.locale_switch_path("/phoenix_kit/nl/products", "en", current_locale: "nl") ==
               "/phoenix_kit/en/products"
    end
  end

  describe "sibling dialects of one base" do
    setup do
      LanguageSettings.put_languages(~w(en-US en-GB es-ES))
      :ok
    end

    test "each dialect is emitted as the segment the site serves it under" do
      assert Routes.locale_switch_path("/phoenix_kit/blog", "en-US") ==
               "/phoenix_kit/en/blog"

      assert Routes.locale_switch_path("/phoenix_kit/blog", "en-GB") ==
               "/phoenix_kit/en-gb/blog"
    end

    test "a lowercase sibling segment is replaced, not stacked" do
      assert Routes.locale_switch_path("/phoenix_kit/en-gb/users/log-in?from=home", "es-ES") ==
               "/phoenix_kit/es/users/log-in?from=home"

      assert Routes.locale_switch_path("/phoenix_kit/en-GB/admin/users", "en-US") ==
               "/phoenix_kit/en/admin/users"

      assert Routes.locale_switch_path("/phoenix_kit/en/admin/users", "en-GB") ==
               "/phoenix_kit/en-gb/admin/users"
    end
  end

  describe "current_locale option" do
    test "an active locale is stripped even if it is no longer offered" do
      assert Routes.locale_switch_path("/phoenix_kit/zz/admin", "en", current_locale: "zz") ==
               "/phoenix_kit/en/admin"
    end
  end

  describe "locale :none" do
    test "drops the locale segment and adds none, for a link to a domain that carries the language" do
      assert Routes.locale_switch_path("/phoenix_kit/ja/users/log-in?from=home", :none) ==
               "/phoenix_kit/users/log-in?from=home"

      assert Routes.locale_switch_path("/phoenix_kit/users/log-in", :none) ==
               "/phoenix_kit/users/log-in"

      assert Routes.locale_switch_path("/phoenix_kit/ja/admin/users", :none) ==
               "/phoenix_kit/admin/users"

      assert Routes.locale_switch_path("/phoenix_kit/ja", :none) == "/phoenix_kit/"
    end

    test "a bare locale root loses its segment whatever follows it" do
      assert Routes.locale_switch_path("/phoenix_kit/ja?x=1", :none) == "/phoenix_kit/?x=1"
      assert Routes.locale_switch_path("/phoenix_kit/ja#top", :none) == "/phoenix_kit/#top"
      assert Routes.locale_switch_path("/phoenix_kit/ja/?x=1", :none) == "/phoenix_kit/?x=1"

      # A segment that merely starts like a locale is not one.
      assert Routes.locale_switch_path("/phoenix_kit/jaguar?x=1", :none) ==
               "/phoenix_kit/jaguar?x=1"
    end

    test "a bare locale root with a query is replaced, not stacked, by a switch" do
      # The bare root is `/es`, not `/es/`, with or without what follows it.
      assert Routes.locale_switch_path("/phoenix_kit/ja?x=1", "es") == "/phoenix_kit/es?x=1"
      assert Routes.locale_switch_path("/phoenix_kit/ja#top", "es") == "/phoenix_kit/es#top"
      assert Routes.locale_switch_path("/phoenix_kit/ja", "es") == "/phoenix_kit/es"
    end

    test "an active locale that is no longer offered is stripped too" do
      assert Routes.locale_switch_path("/phoenix_kit/zz/admin", :none, current_locale: "zz") ==
               "/phoenix_kit/admin"
    end

    test "a dialect sibling's lowercase segment is stripped" do
      LanguageSettings.put_languages(~w(en-US en-GB es-ES))

      assert Routes.locale_switch_path("/phoenix_kit/en-gb/users/log-in", :none) ==
               "/phoenix_kit/users/log-in"
    end
  end

  describe "paths that only begin like the prefix, or carry a query at the root" do
    test "never raise, and never lose what follows" do
      assert Routes.locale_switch_path("/phoenix_kit?x=1", "ja") == "/phoenix_kit/ja?x=1"
      assert Routes.locale_switch_path("/phoenix_kit?", "ja") == "/phoenix_kit/ja?"
      assert Routes.locale_switch_path("/phoenix_kit#top", "ja") == "/phoenix_kit/ja#top"
      assert Routes.locale_switch_path("/phoenix_kit?x=1", :none) == "/phoenix_kit/?x=1"

      # Not under the prefix: a path of its own, as before for a path outside it.
      assert Routes.locale_switch_path("/phoenix_kitn", "ja") == "/phoenix_kit/ja/phoenix_kitn"
      assert Routes.locale_switch_path("docs/x", "ja") == "/phoenix_kit/ja/docs/x"
    end
  end

  describe "domain_page_path/2" do
    test "drops the language's own leading segment, after the prefix when the path has it" do
      assert Routes.domain_page_path("/phoenix_kit/de/docs/x?y=1", "de-DE") ==
               "/phoenix_kit/docs/x?y=1"

      assert Routes.domain_page_path("/de/docs/anfang?x=1", "de-DE") == "/docs/anfang?x=1"
      assert Routes.domain_page_path("/DE/docs", "de-DE") == "/docs"
      assert Routes.domain_page_path("/en/docs/x", "en-US") == "/docs/x"
    end

    test "only the leading segment goes, a repeated one is a page of its own" do
      assert Routes.domain_page_path("/de/de/x", "de-DE") == "/de/x"
      assert Routes.domain_page_path("/phoenix_kit/de/de/x", "de-DE") == "/phoenix_kit/de/x"
    end

    test "a dialect with a domain of its own: its base and its sibling segment both go" do
      LanguageSettings.put_languages(~w(en-US en-GB es-ES))

      assert Routes.domain_page_path("/en-gb/docs/x", "en-GB") == "/docs/x"
      assert Routes.domain_page_path("/EN-GB/docs/x", "en-GB") == "/docs/x"

      assert Routes.domain_page_path("/phoenix_kit/en-gb/docs/x", "en-GB") ==
               "/phoenix_kit/docs/x"

      # `/en/` is en-US's URL, but it is also en-GB's base code: a path given for en-GB with it
      # is en-GB's page, as that domain serves it.
      assert Routes.domain_page_path("/en/docs/x", "en-GB") == "/docs/x"
      # and the other way: en-US's own segment is `en`, not `en-gb`
      assert Routes.domain_page_path("/en-gb/docs/x", "en-US") == "/en-gb/docs/x"
      assert Routes.domain_page_path("/en/docs/x", "en-US") == "/docs/x"
    end

    test "the bare locale root, with what follows it" do
      assert Routes.domain_page_path("/de", "de-DE") == "/"
      assert Routes.domain_page_path("/de?x=1", "de-DE") == "/?x=1"
      assert Routes.domain_page_path("/phoenix_kit/de", "de-DE") == "/phoenix_kit/"
      assert Routes.domain_page_path("/phoenix_kit/de?x=1", "de-DE") == "/phoenix_kit/?x=1"
    end

    test "leaves a path alone when that segment is not the language's own, or not where it is" do
      # another language's segment
      assert Routes.domain_page_path("/de/docs/anfang", "fr-FR") == "/de/docs/anfang"
      # not the leading segment
      assert Routes.domain_page_path("/blog/de/docs/x", "de-DE") == "/blog/de/docs/x"

      assert Routes.domain_page_path("/phoenix_kit/docs/de/x", "de-DE") ==
               "/phoenix_kit/docs/de/x"

      # a segment that only starts like it
      assert Routes.domain_page_path("/deutsch/docs", "de-DE") == "/deutsch/docs"
      # a path that only begins like the prefix is a path of its own
      assert Routes.domain_page_path("/phoenix_kitn/de/x", "de-DE") == "/phoenix_kitn/de/x"
      assert Routes.domain_page_path("/", "de-DE") == "/"
    end

    test "with the kit mounted at the root, every path is a page path" do
      put_prefix("/")

      assert Routes.domain_page_path("/de/docs/x", "de-DE") == "/docs/x"
      assert Routes.domain_page_path("/phoenix_kit/de/docs", "de-DE") == "/phoenix_kit/de/docs"
    end

    test "returns what the path gives, validation is the caller's" do
      put_prefix("/")
      assert Routes.domain_page_path("/de//evil.test/x", "de-DE") == "//evil.test/x"
    end

    defp put_prefix(prefix) do
      previous = Application.fetch_env(:phoenix_kit, :url_prefix)
      Application.put_env(:phoenix_kit, :url_prefix, prefix)
      PhoenixKit.Config.clear_url_prefix_cache()

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, :url_prefix, value)
          :error -> Application.delete_env(:phoenix_kit, :url_prefix)
        end

        PhoenixKit.Config.clear_url_prefix_cache()
      end)
    end
  end
end
