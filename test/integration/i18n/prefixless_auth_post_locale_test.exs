defmodule PhoenixKit.Integration.I18n.PrefixlessAuthPostLocaleTest do
  @moduledoc """
  A form POST to a prefixless auth endpoint (`POST /users/log-in`, which the
  registration, login and password-change forms of the primary language
  submit to) answers in the site's primary language, as the prefixless pages
  themselves do: the flash is translated and the redirect is the primary
  language's URL of the destination.

  Each request starts with the process's Gettext locale at "en": that is what
  a host whose gettext default is English hands the request, whatever the
  site's language.

  `async: false`: the language settings are site-wide.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth

  @moduletag :capture_log
  @password "ValidPassword123!"

  setup %{conn: conn} do
    # A seeded Owner, so the users below get the ordinary role.
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: @password})
    {:ok, _} = Auth.admin_confirm_user(seed)

    {:ok, conn: with_peer(conn)}
  end

  defp unique_email, do: "pl_#{System.unique_integer([:positive])}@example.com"

  # One client per test: the login bucket is per address.
  defp with_peer(conn) do
    ip = {10, 8, rem(System.unique_integer([:positive]), 250), 1}
    {adapter, payload} = conn.adapter
    peer = %{address: ip, port: 111_317, ssl_cert: nil}
    %{conn | adapter: {adapter, Map.put(payload, :peer_data, peer)}, remote_ip: ip}
  end

  defp prefixed(path), do: String.trim_trailing(Config.get_url_prefix(), "/") <> path

  defp post_credentials(conn, path, email, password \\ @password) do
    Gettext.put_locale(PhoenixKitWeb.Gettext, "en")

    post(conn, prefixed(path), %{
      "user" => %{"email_or_username" => email, "password" => password}
    })
  end

  defp new_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
    user
  end

  defp confirmed_user do
    {:ok, user} = Auth.admin_confirm_user(new_user())
    user
  end

  # `segment` is the locale segment the primary language's URLs carry.
  for {label, setup_fun, segment} <- [
        {"a single-language Russian site", :single_language_ru, ""},
        {"a multi-language site with a prefixless Russian primary language",
         :multi_language_ru_prefixless, ""},
        {"a multi-language site with a prefixed Russian primary language",
         :multi_language_ru_prefixed, "/ru"}
      ] do
    describe "on #{label}" do
      setup do
        apply(__MODULE__, unquote(setup_fun), [])
        {:ok, segment: unquote(segment)}
      end

      test "the registration handoff answers in Russian", %{conn: conn, segment: segment} do
        conn = post_credentials(conn, "/users/log-in?_action=registered", new_user().email)

        assert redirected_to(conn) == prefixed(segment <> "/admin")
        assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Аккаунт успешно создан!"
      end

      test "an ordinary sign-in answers in Russian", %{conn: conn, segment: segment} do
        conn = post_credentials(conn, "/users/log-in", confirmed_user().email)

        assert redirected_to(conn) == prefixed(segment <> "/admin")
        assert Phoenix.Flash.get(conn.assigns.flash, :info) == "С возвращением!"
      end

      test "the sign-in after a password change answers in Russian",
           %{conn: conn, segment: segment} do
        conn =
          post_credentials(conn, "/users/log-in?_action=password_updated", confirmed_user().email)

        assert redirected_to(conn) == prefixed(segment <> "/profile/settings")
        assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Пароль успешно обновлён!"
      end

      test "a refused sign-in answers in Russian", %{conn: conn, segment: segment} do
        conn = post_credentials(conn, "/users/log-in", unique_email(), "wrong-password")

        assert redirected_to(conn) == prefixed(segment <> "/users/log-in")

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "Неверная эл. почта/имя пользователя или пароль"
      end
    end
  end

  def single_language_ru do
    Settings.update_setting("languages_enabled", "false")
    {:ok, _} = Languages.set_primary_language("ru")
  end

  def multi_language_ru_prefixless do
    multi_language_ru()
    {:ok, _} = Languages.set_default_language_no_prefix(true)
  end

  def multi_language_ru_prefixed do
    multi_language_ru()
    {:ok, _} = Languages.set_default_language_no_prefix(false)
  end

  defp multi_language_ru do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("ru")
    {:ok, _} = Languages.set_primary_language("ru")
  end
end
