defmodule PhoenixKit.Integration.Notifications.MessagesTest do
  @moduledoc """
  Notification wording an operator changes (item 20, Settings →
  Notifications → Messages): who may, what is checked, which wording a
  reader gets, and that it reaches the email and Telegram messages.
  """

  use PhoenixKit.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Notifications.Channels.Email
  alias PhoenixKit.Notifications.Messages
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  defp scope(roles, permissions) do
    %Scope{
      user: %User{uuid: Ecto.UUID.generate()},
      authenticated?: true,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  defp owner, do: scope(["Owner"], [])

  defp email_parts(subject, markdown), do: %{"subject" => subject, "markdown" => markdown}

  describe "who may change wording" do
    test "the Owner and a holder of settings.messages; nobody else" do
      assert Messages.may_edit?(owner())
      assert Messages.may_edit?(scope(["Editor"], ["settings", "settings.messages"]))
      refute Messages.may_edit?(scope(["Editor"], ["settings"]))
      refute Messages.may_edit?(nil)

      assert {:error, :not_allowed} =
               Messages.save(
                 scope(["Editor"], ["settings"]),
                 "*",
                 "email",
                 "en",
                 email_parts("x", "")
               )

      assert {:error, :not_allowed} = Messages.reset(nil, "*", "email", "en")
    end
  end

  describe "what is checked on save" do
    test "the type, the channel, the language, the size, the variables, raw HTML" do
      o = owner()
      ok = email_parts("Hi", "{{text}}")

      assert {:error, :unknown_type} = Messages.save(o, "no.such", "email", "en", ok)
      assert {:error, :unknown_channel} = Messages.save(o, "*", "sms", "en", ok)
      assert {:error, :bad_locale} = Messages.save(o, "*", "email", "../x", ok)
      assert {:error, :empty} = Messages.save(o, "*", "email", "en", email_parts(" ", ""))

      assert {:error, {:too_long, "subject"}} =
               Messages.save(o, "*", "email", "en", email_parts(String.duplicate("a", 201), ""))

      assert {:error, {:unknown_variables, ["password"]}} =
               Messages.save(o, "*", "email", "en", email_parts("{{password}}", "{{text}}"))

      assert {:error, :raw_html} =
               Messages.save(o, "*", "email", "en", email_parts("x", "{{{text}}}"))

      # A Telegram variable is not an email one, and the other way round.
      assert {:error, {:unknown_variables, ["action_label"]}} =
               Messages.save(o, "*", "telegram", "en", %{"text" => "{{action_label}}"})
    end

    test "a subject is one line; the version guards an older copy" do
      o = owner()

      assert {:ok, %{"subject" => "A B", "version" => v1}} =
               Messages.save(o, "*", "email", "en", email_parts("A\r\nB", "{{text}}"))

      assert {:error, :stale} =
               Messages.save(o, "*", "email", "en", email_parts("C", "{{text}}"), version: 0)

      assert {:ok, %{"version" => v2}} =
               Messages.save(o, "*", "email", "en", email_parts("C", "{{text}}"), version: v1)

      assert v2 != v1

      # A reset from the older copy is refused too; from the current one it works.
      assert {:error, :stale} = Messages.reset(o, "*", "email", "en", version: v1)
      assert Messages.edited_locales("*", "email") == ["en"]
      assert :ok = Messages.reset(o, "*", "email", "en", version: v2)
      assert Messages.edited_locales("*", "email") == []

      # A new save after the reset never reuses the version an open editor holds.
      assert {:ok, %{"version" => v3}} =
               Messages.save(o, "*", "email", "en", email_parts("D", "{{text}}"))

      refute v3 in [v1, v2]
    end
  end

  describe "which wording a reader gets" do
    test "the type's own in their language, then its base language, then everyone's; part by part" do
      o = owner()
      [type | _] = PhoenixKit.Notifications.Types.all_pref_keys()

      {:ok, _} = Messages.save(o, "*", "email", "en", email_parts("Everyone", "{{text}} (all)"))
      {:ok, _} = Messages.save(o, "*", "email", "et", email_parts("Kõik", "{{text}} (kõik)"))
      {:ok, _} = Messages.save(o, type, "email", "et", email_parts("Tüüp", ""))

      # The type's subject; the body from everyone's, in Estonian.
      assert Messages.for_message(type, "email", "et-EE") == %{
               "subject" => "Tüüp",
               "markdown" => "{{text}} (kõik)"
             }

      # A language nobody edited for this type: everyone's English does not
      # reach a Russian reader.
      assert Messages.for_message(type, "email", "ru") == %{}
      assert Messages.for_message(type, "email", "en")["subject"] == "Everyone"

      # `pt_BR` and `pt-BR` are one language.
      {:ok, _} = Messages.save(o, "*", "email", "pt-BR", email_parts("Todos", ""))
      assert Messages.for_message(type, "email", "pt_BR")["subject"] == "Todos"
    end
  end

  describe "the messages sent" do
    defp reader do
      {:ok, user} =
        Auth.register_user(%{
          email: "msg_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      {:ok, user} = Auth.admin_confirm_user(user)
      user
    end

    test "an email takes the saved subject and body; values stay escaped" do
      {:ok, _} =
        Messages.save(
          owner(),
          "*",
          "email",
          "en",
          email_parts("New: {{subject}}", "**{{text}}**")
        )

      user = reader()

      envelope = %{
        recipient_uuid: user.uuid,
        type_key: nil,
        locale: "en",
        title: "Fit the doors",
        text: "<b>Fit</b> the doors",
        url: "https://site.example.test/t/1"
      }

      assert :ok = Email.deliver(envelope, %{})

      assert_email_sent(fn email ->
        assert email.subject == "New: Fit the doors"
        assert email.html_body =~ "<strong>&lt;b&gt;Fit&lt;/b&gt; the doors</strong>"
      end)
    end
  end
end
