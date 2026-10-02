defmodule PhoenixKit.Integration.Users.WelcomeEmailTest do
  @moduledoc """
  The welcome email: off by default, sent once after an address is
  confirmed, from each of the confirmation paths — and never from an
  administrator's confirmation.
  """

  # One test swaps the global `:email_provider`: not async.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Users.WelcomeEmail
  alias PhoenixKit.Utils.Routes

  @password "ValidPassword123!"

  defmodule RaisingProvider do
    @moduledoc false
    def get_active_template_by_name(_name), do: raise("provider down")
  end

  defp unique_email, do: "welcome_#{System.unique_integer([:positive])}@example.com"

  defp create_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: @password})
    user
  end

  defp enable, do: {:ok, _} = Settings.update_setting(WelcomeEmail.setting_key(), "true")

  defp confirmation_token(user) do
    {encoded, user_token} = UserToken.build_email_token(user, "confirm")
    Repo.insert!(user_token)
    encoded
  end

  # Every email this test process was sent, drained from the mailbox.
  defp sent_emails(acc \\ []) do
    receive do
      {:email, email} -> sent_emails([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp welcome_emails(address) do
    Enum.filter(sent_emails(), fn email ->
      email.to == [{"", address}] and email.subject =~ "Welcome to"
    end)
  end

  defp reload(user), do: Repo.get!(User, user.uuid)

  describe "switched off (the default)" do
    test "confirming sends no welcome email and leaves no mark" do
      user = create_user()

      assert {:ok, _} = Auth.confirm_user(confirmation_token(user))

      assert welcome_emails(user.email) == []
      refute Map.has_key?(reload(user).custom_fields || %{}, WelcomeEmail.sent_key())
    end
  end

  describe "switched on" do
    setup do
      enable()
      :ok
    end

    test "the confirmation link sends one welcome email, in the layout with a button" do
      user = create_user()

      assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user(confirmation_token(user))

      assert [email] = welcome_emails(user.email)
      site_url = Routes.base_url()
      assert email.html_body =~ "<!DOCTYPE html>"
      assert email.html_body =~ ~s(<a href="#{site_url}" style="display:inline-block;)
      assert email.text_body =~ user.email
      refute email.text_body =~ "<"

      assert %{"welcome_email_sent_at" => sent_at} = reload(user).custom_fields
      assert {:ok, _, _} = DateTime.from_iso8601(sent_at)
    end

    test "confirming again later sends no second welcome email" do
      user = create_user()
      assert {:ok, confirmed} = Auth.confirm_user(confirmation_token(user))
      assert [_] = welcome_emails(user.email)

      # An administrator unconfirms the address; the reader confirms it again.
      {:ok, unconfirmed} = Auth.admin_unconfirm_user(confirmed)
      assert {:ok, _} = Auth.confirm_user(confirmation_token(unconfirmed))

      assert welcome_emails(user.email) == []
    end

    test "a magic-link sign-in that confirms the account sends it once" do
      user = create_user()

      assert {:ok, confirmed} = Auth.confirm_user_from_external_proof(user)
      assert [_] = welcome_emails(user.email)

      # Already confirmed: nothing to confirm, nothing to send.
      assert {:ok, _} = Auth.confirm_user_from_external_proof(confirmed)
      # A second tab racing with the stale, unconfirmed struct confirms again,
      # and the mark still holds.
      assert {:ok, _} = Auth.confirm_user_from_external_proof(user)
      assert welcome_emails(user.email) == []
    end

    test "magic-link registration sends it once, for the account it creates" do
      email = unique_email()
      {:ok, _email, token} = MagicLinkRegistration.send_registration_link(email)

      assert {:ok, %User{confirmed_at: %_{}}} =
               MagicLinkRegistration.complete_registration(token, %{"password" => @password})

      assert [_] = welcome_emails(email)
    end

    test "an administrator's confirmation sends nothing" do
      user = create_user()

      assert {:ok, %User{confirmed_at: %_{}}} = Auth.toggle_user_confirmation(user)

      assert welcome_emails(user.email) == []
      assert WelcomeEmail.after_confirmation(%User{user | confirmed_at: nil}) == :skipped
    end

    test "two confirmations racing send exactly one" do
      user = create_user()
      {:ok, confirmed} = Auth.admin_confirm_user(user)

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> WelcomeEmail.after_confirmation(confirmed) end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.sort(results) == [:sent, :skipped, :skipped, :skipped]
    end

    test "a send that fails does not fail the confirmation, and is not retried" do
      previous = Application.get_env(:phoenix_kit, :email_provider)
      Application.put_env(:phoenix_kit, :email_provider, __MODULE__.RaisingProvider)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :email_provider, previous),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)

      user = create_user()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %User{confirmed_at: %_{}}} = Auth.confirm_user(confirmation_token(user))
        end)

      assert log =~ "Welcome email to user"
      assert log =~ "provider down"
      assert welcome_emails(user.email) == []
      # Claimed before the send: at most once, never twice.
      assert Map.has_key?(reload(user).custom_fields, WelcomeEmail.sent_key())
    end
  end
end
