defmodule PhoenixKit.Email.AuthEmailsLayoutTest do
  @moduledoc """
  Core's own auth emails reach the reader with an HTML body in the layout.

  Their copy is Markdown: the HTML carries a button and the address written
  out under it, the text is derived from the same copy. Each delivery path is
  checked: `UserNotifier`'s shared templated send, and the magic link, which
  `Mailer` sends on its own.
  """

  use PhoenixKit.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Mailer
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier

  defp user(locale \\ "en") do
    %User{email: "reader@example.test", custom_fields: %{"preferred_locale" => locale}}
  end

  defp assert_in_layout(email, url) do
    assert email.html_body =~ "<!DOCTYPE html>"
    assert email.html_body =~ "<title>#{email.subject}</title>"
    # The button, and the address written out for a client that hides it.
    assert email.html_body =~ ~s(<a href="#{url}" style="display:inline-block;)

    assert email.html_body =~
             ~r/<a href="#{Regex.escape(url)}" style="color:[^"]+;">#{Regex.escape(url)}<\/a>/

    refute email.text_body =~ "<"
    refute email.text_body =~ "]("
    assert email.text_body =~ url
  end

  test "confirmation instructions (UserNotifier's templated send)" do
    url = "https://shop.example.test/users/confirm/abc"
    assert {:ok, email} = UserNotifier.deliver_confirmation_instructions(user(), url)

    assert_in_layout(email, url)
  end

  test "password reset instructions (UserNotifier's templated send), in German" do
    url = "https://shop.example.test/users/reset/abc"
    assert {:ok, email} = UserNotifier.deliver_reset_password_instructions(user("de"), url)

    assert_in_layout(email, url)
    assert email.html_body =~ ~s(<html lang="de">)
  end

  test "magic link (Mailer's own send)" do
    url = "https://shop.example.test/users/magic-link/abc"
    assert {:ok, _} = Mailer.send_magic_link_email(user(), url)

    assert_email_sent(fn email -> assert_in_layout(email, url) end)
  end

  describe "the new login alert's {{failed_attempts}} paragraph" do
    defp login_alert(failed_attempts) do
      Content.resolve(
        "new_login_alert",
        user(),
        %{
          "user_email" => "reader@example.test",
          "login_time" => "2026-09-30 12:00 UTC",
          "ip_address" => "203.0.113.24",
          "location" => "Unknown",
          "browser_os" => "Firefox on Linux",
          "failed_attempts" => failed_attempts,
          "security_url" => "https://shop.example.test/profile/settings"
        },
        &CoreTemplates.new_login_alert_defaults/0
      )
    end

    test "with failures to report it is its own paragraph, in both versions" do
      note = CoreTemplates.failed_attempts_note(2)
      sentence = String.trim(note)
      alert = login_alert(note)

      # Its own <p>, closed before the next one opens — not glued to the
      # sentence after it.
      assert alert.html =~
               ~r/<p[^>]*>#{Regex.escape(sentence)}\s*<\/p>\s*<p[^>]*>If this was you/

      assert alert.text =~ "#{sentence}\n\nIf this was you, no action is needed."
      refute alert.text =~ "\n\n\n"
    end

    test "with nothing to report it leaves no empty paragraph and no gap" do
      alert = login_alert(CoreTemplates.failed_attempts_note(0))

      refute alert.html =~ ~r/<p[^>]*>\s*<\/p>/
      assert alert.html =~ ~r/<\/ul>\s*<p[^>]*>If this was you/
      assert alert.text =~ "Device: Firefox on Linux\n\nIf this was you"
      refute alert.text =~ "\n\n\n"
    end
  end

  test "a site_url that is not http(s) is printed, never linked" do
    {:ok, _} = Settings.update_setting("site_url", "javascript:alert(1)")

    assert {:ok, _} = Mailer.send_magic_link_email(user(), "https://a.test/m")

    assert_email_sent(fn email ->
      refute email.html_body =~ ~s(href="javascript)
      assert email.html_body =~ "javascript:alert(1)"
    end)
  end
end
