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

      assert Routes.locale_switch_path("/phoenix_kit/nl/products", "en") ==
               "/phoenix_kit/en/nl/products"
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

  describe "current_locale option" do
    test "an active locale is stripped even if it is no longer offered" do
      assert Routes.locale_switch_path("/phoenix_kit/zz/admin", "en", current_locale: "zz") ==
               "/phoenix_kit/en/admin"
    end
  end
end
