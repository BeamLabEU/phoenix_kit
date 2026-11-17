defmodule PhoenixKitWeb.OAuth.BrowserBindingTest do
  @moduledoc """
  A consent request belongs to the browser that made the authorization request: the consent URL
  is a capability that can be relayed ("open this link to continue"), and a signed-in
  administrator who opens a relayed one must not be able to allow a connection somebody else
  started. The binding is a cookie with a random nonce; the stored request is keyed by it
  (`PhoenixKit.API.OAuth.Requests`).
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.OAuth.Pages

  @read "testkit.items:read"

  setup do
    setup_api()
    enable_oauth!()
    {user, _role} = holder(["dashboard"])
    {victim, _role} = holder(["dashboard", "settings"])
    {_verifier, challenge} = pkce()

    %{user: user, victim: victim, client: client!(), challenge: challenge}
  end

  defp start(client, challenge) do
    conn = authorize(browser(), authorize_params(client, challenge))
    {conn, consent_id(conn)}
  end

  defp allow_form, do: %{"decision" => "allow", "scopes" => [@read], "days" => "30"}

  # The page in the site's default language (en-US in the test install), as the controller shows it.
  defp start_again_page, do: IO.iodata_to_binary(Pages.start_again(%{lang: "en-US"}))

  describe "the cookie" do
    test "is a random nonce, HttpOnly, Lax, limited to the flow's path, valid for an hour", %{
      client: client,
      challenge: challenge
    } do
      {conn, _id} = start(client, challenge)

      assert %{value: value, http_only: true, same_site: "Lax", max_age: 3600, path: path} =
               conn.resp_cookies[browser_cookie()]

      assert Requests.browser?(value)
      assert path == Routes.path("/oauth")
    end

    test "is Secure when the canonical origin is https, whatever scheme the request shows", %{
      client: client,
      challenge: challenge
    } do
      put_setting("site_url", "https://shop.test")

      # A TLS-terminating proxy hands the application a plain `http` connection.
      conn = authorize(browser(), authorize_params(client, challenge))
      assert conn.scheme == :http
      assert %{secure: true} = conn.resp_cookies[browser_cookie()]
    end

    test "is not Secure when the canonical origin is http, even over a request that shows https",
         %{client: client, challenge: challenge} do
      put_setting("site_url", "http://shop.test")

      conn = %{browser() | scheme: :https}
      answer = authorize(conn, authorize_params(client, challenge))
      assert %{secure: false} = answer.resp_cookies[browser_cookie()]
    end

    test "is not set when the request is refused (an error page has no use for it)", %{
      client: client,
      challenge: challenge
    } do
      params =
        authorize_params(client, challenge, %{"redirect_uri" => "https://other.example/cb"})

      conn = authorize(browser(), params)

      assert conn.status == 400
      refute Map.has_key?(conn.resp_cookies, browser_cookie())
    end

    test "a browser that already holds a nonce keeps it: two tabs do not undo each other", %{
      client: client,
      challenge: challenge
    } do
      {first, id1} = start(client, challenge)
      nonce = browser_value(first)

      second =
        browser()
        |> put_req_cookie(browser_cookie(), nonce)
        |> authorize(authorize_params(client, challenge))

      assert browser_value(second) == nonce
      id2 = consent_id(second)
      assert id1 != id2

      for id <- [id1, id2] do
        conn = get(put_req_cookie(browser(), browser_cookie(), nonce), path("/consent/" <> id))
        assert redirected_to(conn, 302) =~ "/users/log-in"
      end
    end

    test "a value that is no nonce is replaced, not trusted", %{
      client: client,
      challenge: challenge
    } do
      conn =
        browser()
        |> put_req_cookie(browser_cookie(), "forged")
        |> authorize(authorize_params(client, challenge))

      assert Requests.browser?(browser_value(conn))
      refute browser_value(conn) == "forged"
    end
  end

  describe "a consent URL relayed to a signed-in person elsewhere" do
    test "shows the start-again page and grants nothing, whatever the answer", %{
      victim: victim,
      client: client,
      challenge: challenge
    } do
      {_conn, id} = start(client, challenge)

      page = consent_unbound(browser(victim), id)
      assert page.status == 400
      assert page.resp_body == start_again_page()

      answer = decide_unbound(browser(victim), id, allow_form())
      assert answer.status == 400
      assert answer.resp_body == start_again_page()
      assert get_resp_header(answer, "location") == []

      deny = decide_unbound(browser(victim), id, %{"decision" => "deny"})
      assert deny.status == 400
      assert get_resp_header(deny, "location") == []

      assert Repo.all(Grant) == []
      assert Repo.all(Code) == []
      # Nobody burnt the request: the browser that started it still has its screen.
      assert [%Request{consumed_at: nil}] = Repo.all(Request)
    end

    test "a cookie of another browser does not open it either", %{
      victim: victim,
      client: client,
      challenge: challenge
    } do
      {_conn, id} = start(client, challenge)

      other = put_req_cookie(browser(victim), browser_cookie(), Requests.new_browser())
      assert consent_unbound(other, id).status == 400
      assert decide_unbound(other, id, allow_form()).status == 400
      assert Repo.all(Grant) == []
    end

    test "the disconnect form is bound as well", %{
      victim: victim,
      client: client,
      challenge: challenge
    } do
      {_conn, id} = start(client, challenge)
      code_for(victim, client!(), [@read])
      assert [grant] = Repo.all(Grant)

      answer =
        disconnect_unbound(browser(victim), id, %{"grant" => grant.uuid, "confirm" => "yes"})

      assert answer.status == 400
      assert Repo.reload!(grant).revoked_at == nil
    end
  end

  describe "the browser that started the request" do
    test "gets its screen and its code in one session", %{
      user: user,
      client: client,
      challenge: challenge
    } do
      {_conn, id} = start(client, challenge)

      assert consent(browser(user), id).status == 200

      answer = decide(browser(user), id, allow_form())
      assert answer.status == 302
      assert %{"code" => _code} = location_params(answer)
      assert [%Grant{}] = Repo.all(Grant)
    end
  end
end
