defmodule PhoenixKitWeb.OAuth.ClientLanguageTest do
  @moduledoc """
  The pages that belong to clients that name themselves (a metadata document, a dynamic
  registration) are in the language `PhoenixKitWeb.OAuth.Language` picks, like every other page of
  the flow: the notice that the name is not checked and the address of the document on the
  consent screen, the error pages of such a client from the authorize endpoint, and the page of a
  client that the policy no longer allows. Each carries the switcher, and a chosen language rides
  the links the consent page makes.

  The site here is Estonian by default, with Russian and English (US) enabled.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.API.OAuthCimdStub, as: Stub
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  @moduletag :capture_log
  @claude Stub.claude_id()
  @claude_redirect "https://claude.ai/api/mcp/auth_callback"
  @read "testkit.items:read"
  @notice "Anyone can publish a description of an application under any name, and the name above has not been checked. Allow access only if you started this connection from that application."
  @refused "This connection cannot be started"

  setup do
    setup_api()
    enable_oauth!()
    configure_languages()
    Stub.install!()
    Stub.put(@claude, Stub.claude_document())
    Limits.reset(:cimd_client, @claude)

    {user, _role} = holder(["dashboard", "settings"])
    {_verifier, challenge} = pkce()

    app =
      Repo.insert!(%Client{
        kind: "dcr",
        client_id: "dcr_language_#{System.unique_integer([:positive])}",
        redirect_uris: ["https://app.example/cb"]
      })

    %{user: user, challenge: challenge, app: app}
  end

  defp configure_languages do
    languages =
      for {code, index} <- Enum.with_index(~w(et ru en-US)) do
        %{
          "code" => code,
          "name" => code,
          "native" => "native " <> code,
          "is_default" => index == 0,
          "is_enabled" => true,
          "position" => index
        }
      end

    KeyTestSupport.put_setting("languages_enabled", "true")

    KeyTestSupport.write_setting(fn ->
      Settings.update_json_setting("languages_config", %{"languages" => languages})
    end)
  end

  defp claude, do: %{client_id: @claude, redirect_uris: [@claude_redirect]}

  defp with_header(conn, value), do: Plug.Conn.put_req_header(conn, "accept-language", value)

  defp doc(conn), do: Floki.parse_document!(conn.resp_body)
  defp html_lang(conn), do: conn |> doc() |> Floki.attribute("html", "lang") |> List.first()
  defp title(conn), do: conn |> doc() |> Floki.find("title") |> Floki.text()

  defp translate(locale, msgid),
    do:
      Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
        Gettext.dgettext(PhoenixKitWeb.Gettext, "default", msgid)
      end)

  defp exclude! do
    put_setting("api_oauth_client_policy", "allow_list")
    put_setting("api_oauth_client_allow_hosts", "other.example")
  end

  defp allow_form, do: %{"decision" => "allow", "scopes" => [@read], "days" => "30"}

  test "the texts the tests tell apart do differ" do
    assert translate("ru", @notice) != translate("et", @notice)
    assert translate("en", @notice) == @notice
    assert translate("ru", @refused) != translate("et", @refused)
  end

  describe "the notice of an unverified client on the consent screen" do
    test "is in the language of lang, of the profile, of the header and of the site, in that order",
         %{user: user, challenge: challenge} do
      id = browser() |> authorize(authorize_params(claude(), challenge)) |> consent_id()

      notice = fn conn -> conn |> doc() |> Floki.find("#consent-unverified") |> Floki.text() end

      page = consent(with_header(browser(user), "et"), id, "lang=ru")
      assert html_lang(page) == "ru"
      assert String.trim(notice.(page)) == translate("ru", @notice)

      page = consent(with_header(browser(user), "ru"), id)
      assert html_lang(page) == "ru"
      assert String.trim(notice.(page)) == translate("ru", @notice)

      {:ok, user} = Auth.update_user_locale_preference(user, "en-US")
      page = consent(with_header(browser(user), "ru"), id)
      assert html_lang(page) == "en-US"
      assert String.trim(notice.(page)) == @notice

      {other, _role} = holder(["dashboard", "settings"])
      page = consent(browser(other), id)
      assert html_lang(page) == "et"
      assert String.trim(notice.(page)) == translate("et", @notice)
    end

    test "the address line and the switcher are there, and the links carry the chosen language",
         %{user: user, challenge: challenge} do
      id = browser() |> authorize(authorize_params(claude(), challenge)) |> consent_id()
      html = consent(browser(user), id, "lang=ru") |> doc()

      expected = translate("ru", "The application is described at %{address}")
      [prefix, ""] = String.split(expected, "%{address}")
      text = html |> Floki.find("#consent-client-address") |> Floki.text() |> String.trim()
      assert text == prefix <> "claude.ai"

      assert [_, _, _] = Floki.find(html, "#language-switcher a")
      assert Floki.attribute(html, "a[aria-current]", "id") == ["language-ru"]

      assert Floki.attribute(html, "#language-et", "href") == [
               path("/consent/" <> id) <> "?lang=et"
             ]

      assert Floki.attribute(html, "#consent-form", "action") == [
               path("/consent/" <> id) <> "?lang=ru"
             ]
    end

    test "a client of dynamic registration gets the notice and no address, in the chosen language",
         %{user: user, challenge: challenge, app: app} do
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()
      page = consent(browser(user), id, "lang=ru")
      html = doc(page)

      assert html_lang(page) == "ru"
      assert [] = Floki.find(html, "#consent-client-address")

      assert html |> Floki.find("#consent-unverified") |> Floki.text() |> String.trim() ==
               translate("ru", @notice)
    end

    test "the redirect from the authorize endpoint keeps the chosen language", %{
      challenge: challenge
    } do
      conn = authorize(browser(), Map.put(authorize_params(claude(), challenge), "lang", "ru"))
      assert conn.status == 302
      assert URI.parse(location(conn)).query == "lang=ru"

      conn = authorize(with_header(browser(), "ru"), authorize_params(claude(), challenge))
      assert conn.status == 302
      assert URI.parse(location(conn)).query == nil
    end
  end

  describe "the error pages of an unverified client" do
    test "an error after the redirect is confirmed is our page, in the chosen language, with the switcher",
         %{challenge: challenge} do
      params =
        claude()
        |> authorize_params(challenge, %{"code_challenge_method" => "plain", "state" => "abc"})

      page = authorize(browser(), Map.put(params, "lang", "ru"))
      assert page.status == 400
      assert get_resp_header(page, "location") == []
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", @refused)
      assert [_, _, _] = page |> doc() |> Floki.find("#language-switcher a")
      assert page |> doc() |> Floki.attribute("a[aria-current]", "id") == ["language-ru"]

      page = authorize(with_header(browser(), "ru"), params)
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", @refused)

      page = authorize(browser(), params)
      assert html_lang(page) == "et"
      assert title(page) == translate("et", @refused)
    end

    test "a document that cannot be had is the page of an unknown client, in the chosen language",
         %{challenge: challenge} do
      Stub.put(@claude, {:error, {:http_status, 500}})

      page = authorize(browser(), Map.put(authorize_params(claude(), challenge), "lang", "ru"))
      assert page.status == 400
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", @refused)
    end

    test "too many fetches of one client: the 429 page is in the chosen language and keeps retry-after",
         %{challenge: challenge} do
      put_setting("api_oauth_cimd_client_per_min", 1)
      Stub.put(@claude, {:error, {:http_status, 500}})
      assert authorize(browser(), authorize_params(claude(), challenge)).status == 400

      page = authorize(with_header(browser(), "ru"), authorize_params(claude(), challenge))
      assert page.status == 429
      assert [_] = get_resp_header(page, "retry-after")
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", @refused)
      assert [_, _, _] = page |> doc() |> Floki.find("#language-switcher a")

      assert get_resp_header(page, "vary") |> Enum.join(",") |> String.downcase() =~
               "accept-language"
    end
  end

  describe "a client the policy no longer allows" do
    test "the screen is refused in the chosen language, with the switcher", %{
      user: user,
      challenge: challenge,
      app: app
    } do
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()
      exclude!()

      page = consent(browser(user), id, "lang=ru")
      assert page.status == 400
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", @refused)
      assert [] = page |> doc() |> Floki.find("#consent-form")
      assert [_, _, _] = page |> doc() |> Floki.find("#language-switcher a")

      assert page |> doc() |> Floki.attribute("#language-et", "href") == [
               path("/consent/" <> id) <> "?lang=et"
             ]

      page = consent(with_header(browser(user), "ru"), id)
      assert html_lang(page) == "ru"
    end

    test "the answer of the form is refused in the language the form carried", %{
      user: user,
      challenge: challenge,
      app: app
    } do
      id = browser() |> authorize(authorize_params(app, challenge)) |> consent_id()
      exclude!()

      page = decide(with_header(browser(user), "et"), id, allow_form(), "lang=ru")
      assert page.status == 400
      assert get_resp_header(page, "location") == []
      assert html_lang(page) == "ru"
      assert title(page) == translate("ru", @refused)
      assert [_, _, _] = page |> doc() |> Floki.find("#language-switcher a")
      assert page |> doc() |> Floki.attribute("a[aria-current]", "id") == ["language-ru"]
      assert Repo.all(Grant) == []
    end
  end
end
