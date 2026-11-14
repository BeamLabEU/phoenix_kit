defmodule PhoenixKit.Integration.Users.EmailDomainTest do
  @moduledoc """
  The email address check at sign-up (`PhoenixKit.Users.EmailDomain`: a DNS
  check of the domain and a "did you mean" hint), its switch on Settings →
  Authorization → Abuse protection, and the rule that an unconfirmed account
  gets no mail it did not ask for (`Auth.unsolicited_mail_allowed?/1`).

  DNS is `StubDns` here (`:email_domain_resolver`); the check is off in
  `config/test.exs` and switched on per test.
  """

  # Swaps application env.
  use PhoenixKitWeb.ConnCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Notifications.Channels.Email, as: EmailChannel
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Users.EmailDomain
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Utils.Routes

  @password "ValidPassword123!"

  defmodule StubDns do
    @moduledoc false
    # The domain does not exist.
    def resolve("dead.test", _type), do: {:error, :nxdomain}
    # RFC 7505: "this domain takes no mail".
    def resolve("nullmx.test", :mx), do: {:ok, ["."]}
    # No MX, but an address: mail goes there.
    def resolve("nomx.test", :mx), do: {:ok, []}
    def resolve("nomx.test", :a), do: {:ok, ["address"]}
    def resolve("nomx.test", :aaaa), do: {:ok, []}
    # Exists, and has nothing mail could go to.
    def resolve("nothing.test", _type), do: {:ok, []}
    def resolve("slow.test", _type), do: {:error, :unknown}
    def resolve("crash.test", _type), do: raise("resolver blew up")
    def resolve(_domain, :mx), do: {:ok, ["mx.mail.test"]}
    def resolve(_domain, _type), do: {:ok, ["address"]}
  end

  setup do
    for {key, value} <- [email_domain_check: true, email_domain_resolver: {StubDns, :resolve}] do
      previous = Application.fetch_env(:phoenix_kit, key)
      Application.put_env(:phoenix_kit, key, value)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:phoenix_kit, key, old)
          :error -> Application.delete_env(:phoenix_kit, key)
        end
      end)
    end

    :ok
  end

  defp local, do: "ed_#{System.unique_integer([:positive])}"

  describe "check/1" do
    test "refuses only on a definite answer" do
      assert :ok = EmailDomain.check("ann@good.test")
      assert :ok = EmailDomain.check("ann@nomx.test")

      assert {:error, :no_mail_host} = EmailDomain.check("ann@dead.test")
      assert {:error, :no_mail_host} = EmailDomain.check("ann@nullmx.test")
      assert {:error, :no_mail_host} = EmailDomain.check("Ann@Nothing.TEST. ")

      # No answer, or a resolver that fails: the address passes.
      assert :ok = EmailDomain.check("ann@slow.test")
      assert :ok = EmailDomain.check("ann@crash.test")
    end

    test "does not look up what DNS cannot be asked about" do
      assert :ok = EmailDomain.check("ann@[192.0.2.1]")
      assert :ok = EmailDomain.check("ann@почта.рф")
      assert :ok = EmailDomain.check("no-at-sign")
      assert :ok = EmailDomain.check("two@at@dead.test")
      assert :ok = EmailDomain.check(nil)
    end

    test "off by the setting, and off by the configuration whatever the setting says" do
      {:ok, _} = Settings.update_boolean_setting(EmailDomain.setting_key(), false)
      refute EmailDomain.enabled?()
      assert :ok = EmailDomain.check("ann@dead.test")
      assert EmailDomain.suggestion("ann@gmial.com") == nil

      {:ok, _} = Settings.update_boolean_setting(EmailDomain.setting_key(), true)
      assert {:error, :no_mail_host} = EmailDomain.check("ann@dead.test")

      Application.put_env(:phoenix_kit, :email_domain_check, false)
      refute EmailDomain.enabled?()
      assert :ok = EmailDomain.check("ann@dead.test")
    end
  end

  describe "suggest/1" do
    test "corrects the common typos of the big providers" do
      for {typed, corrected} <- [
            {"ann@gmial.com", "ann@gmail.com"},
            {"ann@gnail.com", "ann@gmail.com"},
            {"Ann@Gmail.con", "ann@gmail.com"},
            {"ann@hotmial.co.uk", "ann@hotmail.co.uk"},
            {"ann@yahooo.com", "ann@yahoo.com"},
            {"ann@outlok.com", "ann@outlook.com"},
            {"ann@gmial.con", "ann@gmail.com"},
            {"ann@acme-corp.con", "ann@acme-corp.com"}
          ] do
        assert EmailDomain.suggest(typed) == corrected, "#{typed}"
      end
    end

    test "leaves a real domain alone, a provider one letter from another included" do
      for address <- ~w(ann@gmail.com ann@mail.com ann@ymail.com ann@gmx.net ann@acme.io
                        ann@email.com ann@example.org) do
        assert EmailDomain.suggest(address) == nil, address
      end

      assert EmailDomain.suggest("@gmial.com") == nil
      assert EmailDomain.suggest("not an address") == nil
      assert EmailDomain.suggest(nil) == nil
    end
  end

  describe "sign-up" do
    test "a domain that cannot receive mail is refused; nothing is created or sent", %{conn: conn} do
      email = "#{local()}@dead.test"
      {:ok, view, _html} = live(conn, Routes.path("/users/register"))

      html =
        render_submit(view, "save", %{"user" => %{"email" => email, "password" => @password}})

      assert html =~ "This email domain cannot receive mail"
      refute Auth.get_user_by_email(email)
      assert_no_email_sent()
    end

    test "a domain that can is registered", %{conn: conn} do
      email = "#{local()}@good.test"
      {:ok, view, _html} = live(conn, Routes.path("/users/register"))

      render_submit(view, "save", %{"user" => %{"email" => email, "password" => @password}})

      assert %User{} = Auth.get_user_by_email(email)
    end

    test "the hint appears while typing and fills the field when taken", %{conn: conn} do
      name = local()
      {:ok, view, html} = live(conn, Routes.path("/users/register"))
      refute html =~ "email-suggestion"

      html = render_change(view, "validate", %{"user" => %{"email" => "#{name}@gmial.com"}})
      assert html =~ "Did you mean"
      assert html =~ "#{name}@gmail.com"

      # Taking it tells the browser to fill the field (the form holds the typed
      # password and is not kept on the server); the field's change event then
      # comes back as an ordinary "validate".
      html = view |> element("#email-suggestion button") |> render_click()
      refute html =~ "email-suggestion"
      assert_push_event(view, "phoenix_kit:set_input", %{id: "user_email", value: value})
      assert value == "#{name}@gmail.com"

      # A correct address has no hint.
      refute render_change(view, "validate", %{"user" => %{"email" => "#{name}@gmail.com"}}) =~
               "email-suggestion"
    end

    test "a programmatic registration is not checked" do
      assert {:ok, %User{}} =
               Auth.register_user(%{email: "#{local()}@dead.test", password: @password})
    end

    test "switched off: no hint and no refusal", %{conn: conn} do
      {:ok, _} = Settings.update_boolean_setting(EmailDomain.setting_key(), false)
      email = "#{local()}@dead.test"
      {:ok, view, _html} = live(conn, Routes.path("/users/register"))

      refute render_change(view, "validate", %{"user" => %{"email" => "a@gmial.com"}}) =~
               "email-suggestion"

      render_submit(view, "save", %{"user" => %{"email" => email, "password" => @password}})
      assert %User{} = Auth.get_user_by_email(email)
    end
  end

  describe "the registration link" do
    test "refused for a domain that cannot receive mail" do
      assert {:error, :no_mail_host} =
               MagicLinkRegistration.send_registration_link("#{local()}@nullmx.test")

      assert_no_email_sent()

      assert {:ok, _email, _token} =
               MagicLinkRegistration.send_registration_link("#{local()}@good.test")
    end

    test "the page says so, and shows the hint", %{conn: conn} do
      name = local()
      {:ok, view, _html} = live(conn, Routes.path("/users/register/magic-link"))

      html = render_change(view, "validate", %{"email" => "#{name}@hotmail.con"})
      assert html =~ "#{name}@hotmail.com"

      html = view |> element("#email-suggestion button") |> render_click()
      assert html =~ ~s(value="#{name}@hotmail.com")
      refute html =~ "email-suggestion"

      render_submit(view, "send_magic_link", %{"email" => "#{name}@dead.test"})
      assert render_async(view) =~ "This email domain cannot receive mail"
      assert_no_email_sent()
    end
  end

  describe "mail nobody asked for" do
    defp unconfirmed do
      {:ok, user} = Auth.register_user(%{email: "#{local()}@good.test", password: @password})
      user
    end

    defp envelope(user) do
      %{
        recipient_uuid: user.uuid,
        type_key: nil,
        notification_uuid: nil,
        locale: nil,
        icon: "hero-bell",
        title: "Something happened",
        text: "Something happened to you.",
        url: nil
      }
    end

    test "an unconfirmed account gets no alert and no notification mail" do
      user = unconfirmed()
      refute Auth.unsolicited_mail_allowed?(user)

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_failed_login_alert(user, %{count: 5, window_hours: 24})

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_new_login_alert(user, %{
                 ip_address: "203.0.113.9",
                 first_seen_at: DateTime.utc_now()
               })

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_passkey_added(user, %{name: "Phone", at: DateTime.utc_now()})

      assert {:ok, %{suppressed: true}} =
               UserNotifier.deliver_passkey_removed(user, %{name: "Phone", by_owner?: true})

      # `:ok`, not an error: an error would switch the channel off for good.
      assert :ok = EmailChannel.deliver(envelope(user), %{})

      assert_no_email_sent()
    end

    test "it still gets what its holder asks for" do
      user = unconfirmed()

      assert {:ok, _} = Auth.deliver_user_confirmation_instructions(user, &"/users/confirm/#{&1}")
      assert_email_sent(to: user.email)

      assert {:ok, _} = Auth.deliver_user_reset_password_instructions(user, &"/reset/#{&1}")
      assert_email_sent(to: user.email)
    end

    test "a confirmed account gets them" do
      {:ok, user} = Auth.admin_confirm_user(unconfirmed())
      assert Auth.unsolicited_mail_allowed?(user)

      assert {:ok, _} =
               UserNotifier.deliver_failed_login_alert(user, %{count: 5, window_hours: 24})

      assert_email_sent(to: user.email)

      assert :ok = EmailChannel.deliver(envelope(user), %{})
      assert_email_sent(to: user.email)
    end

    test "a site that does not ask for confirmation mails everyone" do
      {:ok, _} = Settings.update_setting("require_email_confirmation", "false")
      user = unconfirmed()

      assert Auth.unsolicited_mail_allowed?(user)
      assert :ok = EmailChannel.deliver(envelope(user), %{})
      assert_email_sent(to: user.email)
    end
  end

  describe "Settings → Authorization → Abuse protection" do
    setup %{conn: conn} do
      {user, _token} = create_admin_user()
      %{conn: log_in_user(conn, user)}
    end

    test "the switch is on by default and saves", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/authorization?tab=protection"))

      assert has_element?(view, "#email-domain-check-enabled[checked]")

      html =
        view
        |> form("#email-check-settings-form", %{email_check: %{enabled: "false"}})
        |> render_submit()

      assert html =~ "Email address check saved."
      refute Settings.get_boolean_setting(EmailDomain.setting_key(), true)
      refute has_element?(view, "#email-domain-check-enabled[checked]")
    end

    test "says when the configuration has it switched off", %{conn: conn} do
      Application.put_env(:phoenix_kit, :email_domain_check, false)

      {:ok, _view, html} =
        live(conn, Routes.path("/admin/settings/authorization?tab=protection"))

      assert html =~ "Switched off in the application&#39;s configuration"
    end

    test "the settings form cannot write the switch", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/authorization"))

      render_submit(view, "save_settings", %{
        "settings" => %{"email_domain_check_enabled" => "false"}
      })

      assert Settings.get_boolean_setting(EmailDomain.setting_key(), true)
    end
  end
end
