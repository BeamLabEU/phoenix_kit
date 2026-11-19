defmodule PhoenixKitWeb.OAuth.SigninReturnTest do
  @moduledoc """
  The whole round trip of a person who is not signed in when the application sends them to
  `/oauth/authorize`: authorize, the consent URL, the sign-in the core really offers, the way back
  to the same consent page, "Allow", the code, the tokens. One browser throughout: the requests
  carry the cookies the answers set (`Phoenix.ConnTest.recycle/2`), nothing is handed over by the
  test, so what the sign-in clears or keeps is what the flow gets.

  Signing in renews the session and clears it, so the binding of the request to its browser
  (`PhoenixKit.API.OAuth.Requests`) must survive that: it does, because it rides a cookie.
  Covered: a password sign-in, a magic link opened in the same browser, and the one-time link
  the passkey sign-in ends in. **Not covered**: the WebAuthn ceremony of a passkey (done in the
  sign-in LiveView, in the browser) and the "Sign in with Google" callback (it needs the provider's
  answer); both end in the same `PhoenixKitWeb.Users.Auth.log_in_user/3` that the three
  covered ways end in.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthFlowSupport

  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0, pkce: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias Phoenix.ConnTest
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.MagicLink
  alias PhoenixKit.Users.Passkeys
  alias PhoenixKit.Utils.Routes

  @read "testkit.items:read"
  @password "ValidPassword123!"

  setup do
    setup_api()
    enable_oauth!()
    {user, _role} = holder(["dashboard"])
    %{user: user, client: client!()}
  end

  # The next request of the same browser: the cookies of the last answer, the same address.
  defp next(conn), do: ConnTest.recycle(conn, ~w(accept x-forwarded-for))

  defp start(client) do
    {verifier, challenge} = pkce()
    params = authorize_params(client, challenge)
    started = authorize(browser(), params)
    assert started.status == 302
    %{started: started, id: consent_id(started), params: params, verifier: verifier}
  end

  # Opens the consent URL as an anonymous visitor: sent to the sign-in, the way back remembered.
  defp visit_anonymous(%{started: started, id: id}) do
    visit = get(next(started), path("/consent/" <> id))
    assert redirected_to(visit, 302) =~ "/users/log-in"
    assert get_session(visit, :user_return_to) == path("/consent/" <> id)
    visit
  end

  # After the sign-in the browser is sent back to the consent page it came from; it shows the
  # screen, and "Allow" gives a code that the token endpoint exchanges.
  defp finish(signed_in, flow, client) do
    assert redirected_to(signed_in, 302) =~ path("/consent/" <> flow.id)

    page = get(next(signed_in), redirected_to(signed_in))
    assert page.status == 200
    assert [_] = page.resp_body |> Floki.parse_document!() |> Floki.find("#consent-form")

    answer =
      post(next(page), path("/consent/" <> flow.id), %{
        "decision" => "allow",
        "scopes" => [@read],
        "days" => "30"
      })

    assert answer.status == 302
    assert %{"code" => code, "state" => state} = location_params(answer)
    assert state == flow.params["state"]

    tokens =
      exchange_code(%{
        code: code,
        verifier: flow.verifier,
        client: client,
        redirect_uri: flow.params["redirect_uri"]
      })

    assert tokens.status == 200
    assert %{"access_token" => "pkoa_" <> _, "scope" => @read} = body(tokens)
    assert [%Grant{activated_at: %DateTime{}}] = Repo.all(Grant)
  end

  describe "an anonymous visitor" do
    test "signs in with a password and lands on the same consent page", %{
      user: user,
      client: client
    } do
      flow = start(client)
      visit = visit_anonymous(flow)

      signed_in =
        post(next(visit), Routes.path("/users/log-in"), %{
          "user" => %{"email" => user.email, "password" => @password}
        })

      finish(signed_in, flow, client)
    end

    test "signs in with a magic link opened in the same browser", %{user: user, client: client} do
      flow = start(client)
      visit = visit_anonymous(flow)

      {:ok, _user, token} = MagicLink.generate_magic_link(user.email)
      signed_in = get(next(visit), Routes.path("/users/magic-link/" <> token))

      finish(signed_in, flow, client)
    end

    test "signs in through the passkey's one-time link and lands on the same consent page", %{
      user: user,
      client: client
    } do
      put_setting("passkey_login_enabled", "true")

      flow = start(client)
      visit = visit_anonymous(flow)

      {:ok, token} = Passkeys.mint_login_token(user)
      signed_in = get(next(visit), Routes.path("/users/passkey/finish/" <> token))

      finish(signed_in, flow, client)
    end
  end

  describe "the binding survives the sign-in only in the browser that started it" do
    test "the consent URL signed in elsewhere is a request that is gone", %{
      user: user,
      client: client
    } do
      flow = start(client)

      # Somebody else's browser: a fresh jar, signed in as the person the link was relayed to.
      elsewhere =
        post(browser(), Routes.path("/users/log-in"), %{
          "user" => %{"email" => user.email, "password" => @password}
        })

      assert redirected_to(elsewhere, 302)

      page = get(next(elsewhere), path("/consent/" <> flow.id))
      assert page.status == 400
      assert [] = page.resp_body |> Floki.parse_document!() |> Floki.find("#consent-form")

      assert Repo.all(Grant) == []
    end
  end
end
