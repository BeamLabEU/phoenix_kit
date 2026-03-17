defmodule PhoenixKit.Integration.Users.EmailConfirmationTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth

  defp unique_email, do: "confirm_#{System.unique_integer([:positive])}@example.com"

  defp create_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    user
  end

  describe "deliver_user_confirmation_instructions/2" do
    test "generates confirmation token for unconfirmed user" do
      user = create_user()
      assert is_nil(user.confirmed_at)

      assert {:ok, _} =
               Auth.deliver_user_confirmation_instructions(
                 user,
                 &"http://example.com/confirm/#{&1}"
               )
    end

    test "returns error for already confirmed user" do
      user = create_user()
      {:ok, confirmed} = Auth.admin_confirm_user(user)

      assert {:error, :already_confirmed} =
               Auth.deliver_user_confirmation_instructions(
                 confirmed,
                 &"http://example.com/confirm/#{&1}"
               )
    end
  end

  describe "confirm_user/1" do
    test "confirms user with valid token" do
      user = create_user()

      # Extract token by capturing the URL callback
      {:ok, %Swoosh.Email{} = email} =
        Auth.deliver_user_confirmation_instructions(user, &"http://example.com/confirm/#{&1}")

      # Extract token from the email body
      [_, token] = Regex.run(~r/confirm\/([^\s"<]+)/, email.html_body || email.text_body)

      assert {:ok, confirmed} = Auth.confirm_user(token)
      assert confirmed.confirmed_at != nil
      assert confirmed.uuid == user.uuid
    end

    test "returns error for invalid token" do
      assert :error = Auth.confirm_user("invalid_token")
    end
  end

  describe "admin_confirm_user/1" do
    test "confirms user without token" do
      user = create_user()
      assert is_nil(user.confirmed_at)

      {:ok, confirmed} = Auth.admin_confirm_user(user)
      assert confirmed.confirmed_at != nil
    end
  end

  describe "admin_unconfirm_user/1" do
    test "unconfirms a confirmed user" do
      user = create_user()
      {:ok, confirmed} = Auth.admin_confirm_user(user)
      assert confirmed.confirmed_at != nil

      {:ok, unconfirmed} = Auth.admin_unconfirm_user(confirmed)
      assert is_nil(unconfirmed.confirmed_at)
    end
  end

  describe "toggle_user_confirmation/1" do
    test "confirms unconfirmed user" do
      user = create_user()
      {:ok, toggled} = Auth.toggle_user_confirmation(user)
      assert toggled.confirmed_at != nil
    end

    test "unconfirms confirmed user" do
      user = create_user()
      {:ok, confirmed} = Auth.admin_confirm_user(user)
      {:ok, toggled} = Auth.toggle_user_confirmation(confirmed)
      assert is_nil(toggled.confirmed_at)
    end
  end
end
