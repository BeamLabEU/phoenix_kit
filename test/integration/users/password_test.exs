defmodule PhoenixKit.Integration.Users.PasswordTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth

  defp unique_email, do: "pw_#{System.unique_integer([:positive])}@example.com"
  @valid_password "ValidPassword123!"
  @new_password "NewPassword456!"

  defp create_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: @valid_password})
    user
  end

  describe "update_user_password/3" do
    test "updates password with valid current password" do
      user = create_user()

      assert {:ok, updated} =
               Auth.update_user_password(user, @valid_password, %{
                 password: @new_password,
                 password_confirmation: @new_password
               })

      assert {:ok, _} = Auth.get_user_by_email_and_password(updated.email, @new_password)
    end

    test "rejects wrong current password" do
      user = create_user()

      assert {:error, changeset} =
               Auth.update_user_password(user, "WrongPassword!", %{
                 password: @new_password,
                 password_confirmation: @new_password
               })

      assert errors_on(changeset).current_password != []
    end

    test "rejects password confirmation mismatch" do
      user = create_user()

      assert {:error, changeset} =
               Auth.update_user_password(user, @valid_password, %{
                 password: @new_password,
                 password_confirmation: "DoesNotMatch456!"
               })

      assert errors_on(changeset).password_confirmation != []
    end

    test "invalidates all session tokens" do
      user = create_user()
      token = Auth.generate_user_session_token(user)

      {:ok, _} =
        Auth.update_user_password(user, @valid_password, %{
          password: @new_password,
          password_confirmation: @new_password
        })

      assert is_nil(Auth.get_user_by_session_token(token))
    end

    test "invalidates multiple session tokens after password change" do
      user = create_user()
      token1 = Auth.generate_user_session_token(user)
      token2 = Auth.generate_user_session_token(user)

      {:ok, _} =
        Auth.update_user_password(user, @valid_password, %{
          password: @new_password,
          password_confirmation: @new_password
        })

      assert is_nil(Auth.get_user_by_session_token(token1))
      assert is_nil(Auth.get_user_by_session_token(token2))
    end
  end

  describe "admin_update_user_password/3" do
    test "updates password without requiring current password" do
      user = create_user()

      assert {:ok, updated} =
               Auth.admin_update_user_password(user, %{
                 password: @new_password,
                 password_confirmation: @new_password
               })

      assert {:ok, _} = Auth.get_user_by_email_and_password(updated.email, @new_password)
    end
  end

  describe "reset password workflow" do
    test "deliver_user_reset_password_instructions/2 sends email" do
      user = create_user()

      assert {:ok, _} =
               Auth.deliver_user_reset_password_instructions(
                 user,
                 &"http://example.com/reset/#{&1}"
               )
    end

    test "get_user_by_reset_password_token/1 returns user for valid token" do
      user = create_user()

      {:ok, %Swoosh.Email{} = email} =
        Auth.deliver_user_reset_password_instructions(
          user,
          &"http://example.com/reset/#{&1}"
        )

      [_, token] = Regex.run(~r/reset\/([^\s"<]+)/, email.html_body || email.text_body)

      found = Auth.get_user_by_reset_password_token(token)
      assert found.uuid == user.uuid
    end

    test "reset_user_password/2 updates password and invalidates tokens" do
      user = create_user()
      session_token = Auth.generate_user_session_token(user)

      {:ok, %Swoosh.Email{} = email} =
        Auth.deliver_user_reset_password_instructions(
          user,
          &"http://example.com/reset/#{&1}"
        )

      [_, token] = Regex.run(~r/reset\/([^\s"<]+)/, email.html_body || email.text_body)
      reset_user = Auth.get_user_by_reset_password_token(token)

      assert {:ok, _} =
               Auth.reset_user_password(reset_user, %{
                 password: @new_password,
                 password_confirmation: @new_password
               })

      # Old session invalidated
      assert is_nil(Auth.get_user_by_session_token(session_token))

      # New password works
      assert {:ok, _} = Auth.get_user_by_email_and_password(user.email, @new_password)
    end

    test "returns nil for invalid reset token" do
      assert is_nil(Auth.get_user_by_reset_password_token("invalid"))
    end
  end
end
