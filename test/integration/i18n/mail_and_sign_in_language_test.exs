defmodule PhoenixKit.Integration.I18n.MailAndSignInLanguageTest do
  @moduledoc """
  The language of account mail and where sign-in lands.

    * An account email's text and its link are in one language: the
      recipient's saved one, else (for mail they asked for themselves) the
      page's, else the site's. Never the language of an admin who sends it.
    * A person without a saved language gets the page's saved at sign-in.
    * After sign-in they land in their saved language, unless the sign-in
      page was in another one or the destination names one.

  `async: false`: languages, the mailbox and the login rate limit are global.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @moduletag :capture_log
  @password "ValidPassword123!"

  setup do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("de-DE")

    previous = Gettext.get_locale(PhoenixKitWeb.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, previous) end)
    :ok
  end

  defp user!(preferred \\ nil) do
    {:ok, user} =
      Auth.register_user(%{
        email: "lang_#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    if preferred do
      {:ok, user} = Auth.update_user_locale_preference(user, preferred)
      user
    else
      user
    end
  end

  # One client per test: the login bucket is per address.
  defp with_peer(conn) do
    ip = {10, 9, rem(System.unique_integer([:positive]), 250), 1}
    {adapter, payload} = conn.adapter
    peer = %{address: ip, port: 111_317, ssl_cert: nil}
    %{conn | adapter: {adapter, Map.put(payload, :peer_data, peer)}, remote_ip: ip}
  end

  defp confirm_link(email),
    do: Regex.run(~r{https?://[^\s"]+/users/confirm/[^\s"<]+}, email.text_body)

  describe "account mail" do
    test "an admin's send follows the recipient's saved language, text and link alike" do
      english = user!()

      {:ok, _} =
        Auth.deliver_user_confirmation_instructions(english, &Routes.url("/users/confirm/#{&1}"))

      assert_email_sent(fn email -> send(self(), {:english_subject, email.subject}) end)
      assert_received {:english_subject, english_subject}

      german = user!("de-DE")
      # The admin works in English: the mail must not follow them.
      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")

      {:ok, _} =
        Auth.deliver_user_confirmation_instructions(german, &Routes.url("/users/confirm/#{&1}"))

      assert_email_sent(fn email ->
        assert [link] = confirm_link(email)
        assert link =~ "/de/users/confirm/"
        refute email.subject == english_subject
        true
      end)
    end

    test "an admin working in German sends a person with no saved language the site's language" do
      user = user!()
      Gettext.put_locale(PhoenixKitWeb.Gettext, "de")

      {:ok, _} =
        Auth.deliver_user_reset_password_instructions(
          user,
          &Routes.url("/users/reset-password/#{&1}"),
          rate_limit: false
        )

      assert_email_sent(fn email ->
        refute email.text_body =~ "/de/users/reset-password/"
        true
      end)
    end

    test "mail a person asks for on a German page comes in German when they have no saved language" do
      user = user!()

      {:ok, _} =
        Auth.deliver_user_confirmation_instructions(user, &Routes.url("/users/confirm/#{&1}"),
          locale: "de-DE"
        )

      assert_email_sent(fn email ->
        assert [link] = confirm_link(email)
        assert link =~ "/de/users/confirm/"
      end)
    end

    test "a saved language wins over the page's" do
      user = user!("en-US")

      {:ok, _} =
        Auth.deliver_user_confirmation_instructions(user, &Routes.url("/users/confirm/#{&1}"),
          locale: "de-DE"
        )

      assert_email_sent(fn email ->
        assert [link] = confirm_link(email)
        refute link =~ "/de/"
        true
      end)
    end

    test "a magic link asked for on a German page comes in German", %{conn: conn} do
      user = user!()
      {:ok, _} = Auth.admin_confirm_user(user)

      {:ok, view, _html} = live(with_peer(conn), Routes.path("/users/magic-link", locale: "de"))

      view
      |> form("form", %{"magic_link" => %{"email" => user.email}})
      |> render_submit()

      render_async(view)

      assert_email_sent(fn email -> assert email.text_body =~ "/de/users/magic-link/" end)
    end

    test "Routes.url/2 builds a link in the language it is given" do
      assert Routes.url("/users/log-in", locale: "de-DE") =~ "/de/users/log-in"
      refute Routes.url("/users/log-in", locale: "en-US") =~ "/de/"
    end
  end

  describe "remember_page_locale/2" do
    test "saves the page's language for a person with none" do
      assert Auth.remember_page_locale(user!(), "de-DE").custom_fields["preferred_locale"] ==
               "de-DE"
    end

    test "keeps a saved language, and saves nothing for the site's own" do
      assert Auth.remember_page_locale(user!("en-US"), "de-DE").custom_fields["preferred_locale"] ==
               "en-US"

      refute Map.has_key?(
               Auth.remember_page_locale(user!(), "en-US").custom_fields || %{},
               "preferred_locale"
             )
    end
  end

  describe "sign-in" do
    defp sign_in(conn, path, user, extra \\ %{}) do
      post(with_peer(conn), path, %{
        "user" => Map.merge(%{"email" => user.email, "password" => @password}, extra)
      })
    end

    defp confirmed!(preferred) do
      {:ok, user} = Auth.admin_confirm_user(user!(preferred))
      user
    end

    test "lands in the saved language when the sign-in page named none", %{conn: conn} do
      conn = sign_in(conn, Routes.path("/users/log-in", locale: "en"), confirmed!("de-DE"))
      assert redirected_to(conn) =~ Routes.path("/admin", locale: "de")
    end

    test "a destination that names a language keeps it", %{conn: conn} do
      user = confirmed!("de-DE")

      conn =
        sign_in(conn, Routes.path("/users/log-in", locale: "en"), user, %{
          "return_to" => Routes.path("/admin/users", locale: "de")
        })

      assert redirected_to(conn) == Routes.path("/admin/users", locale: "de")
    end

    test "a saved language keeps a host destination that has no translated route", %{conn: conn} do
      destination = "/__test/crawlers-no-index-probe?from=login"

      conn =
        sign_in(conn, Routes.path("/users/log-in", locale: "en"), confirmed!("de-DE"), %{
          "return_to" => destination
        })

      assert redirected_to(conn) == destination
    end

    test "a sign-in page in another language wins, and saves it for a person with none",
         %{conn: conn} do
      user = confirmed!(nil)
      conn = sign_in(conn, Routes.path("/users/log-in", locale: "de"), user)

      assert redirected_to(conn) =~ Routes.path("/", locale: "de")
      assert Auth.get_user!(user.uuid).custom_fields["preferred_locale"] =~ "de"
    end

    test "a person with no saved language signing in on the site's language stays there",
         %{conn: conn} do
      user = confirmed!(nil)
      conn = sign_in(conn, Routes.path("/users/log-in", locale: "en"), user)

      refute redirected_to(conn) =~ "/de/"
      refute Map.has_key?(Auth.get_user!(user.uuid).custom_fields || %{}, "preferred_locale")
    end
  end
end
