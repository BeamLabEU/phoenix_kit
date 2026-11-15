defmodule PhoenixKit.Integration.I18n.PrefixlessAuthPostLocaleTest do
  @moduledoc """
  A form POST to a prefixless auth endpoint (`POST /users/log-in`, which the
  registration and login forms of the primary language submit to) answers in
  the site's primary language, as the prefixless pages themselves do: the
  flash is translated and the redirect carries no other language's segment.

  The process locale is set to "en" before each request: that is what a host
  whose gettext default is English hands the request, whatever the site's
  language.

  `async: false`: languages and the process locale are global.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth

  @moduletag :capture_log
  @password "ValidPassword123!"

  setup %{conn: conn} do
    previous = Gettext.get_locale(PhoenixKitWeb.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, previous) end)

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

  defp prefixless(path), do: String.trim_trailing(Config.get_url_prefix(), "/") <> path

  defp post_credentials(conn, path, user) do
    Gettext.put_locale(PhoenixKitWeb.Gettext, "en")

    post(conn, prefixless(path), %{
      "user" => %{"email_or_username" => user.email, "password" => @password}
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

  for {label, setup_fun} <- [
        {"a single-language Russian site", :single_language_ru},
        {"a multi-language site whose primary language is Russian", :multi_language_ru}
      ] do
    describe "on #{label}" do
      setup do
        apply(__MODULE__, unquote(setup_fun), [])
        :ok
      end

      test "the registration handoff says so in Russian and stays out of /en/", %{conn: conn} do
        conn = post_credentials(conn, "/users/log-in?_action=registered", new_user())

        refute redirected_to(conn) =~ "/en/"
        assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Аккаунт успешно создан!"
      end

      test "an ordinary sign-in says so in Russian and stays out of /en/", %{conn: conn} do
        conn = post_credentials(conn, "/users/log-in", confirmed_user())

        refute redirected_to(conn) =~ "/en/"
        assert Phoenix.Flash.get(conn.assigns.flash, :info) == "С возвращением!"
      end

      test "a refused sign-in says so in Russian and stays out of /en/", %{conn: conn} do
        Gettext.put_locale(PhoenixKitWeb.Gettext, "en")

        conn =
          post(conn, prefixless("/users/log-in"), %{
            "user" => %{"email_or_username" => unique_email(), "password" => "wrong-password"}
          })

        refute redirected_to(conn) =~ "/en/"

        assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
                 "Неверная эл. почта/имя пользователя или пароль"
      end
    end
  end

  def single_language_ru do
    Settings.update_setting("languages_enabled", "false")
    {:ok, _} = Languages.set_primary_language("ru")
  end

  def multi_language_ru do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("ru")
    {:ok, _} = Languages.set_primary_language("ru")
  end
end
