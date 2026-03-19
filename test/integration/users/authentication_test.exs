defmodule PhoenixKit.Integration.Users.AuthenticationTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth

  defp unique_email, do: "auth_#{System.unique_integer([:positive])}@example.com"
  defp valid_password, do: "ValidPassword123!"

  defp create_user(overrides \\ %{}) do
    attrs = Map.merge(%{email: unique_email(), password: valid_password()}, overrides)
    {:ok, user} = Auth.register_user(attrs)
    {user, attrs}
  end

  describe "get_user_by_email_and_password/3" do
    test "returns user with correct credentials" do
      {user, attrs} = create_user()

      assert {:ok, found} = Auth.get_user_by_email_and_password(attrs.email, attrs.password)
      assert found.uuid == user.uuid
    end

    test "returns error with wrong password" do
      {_user, attrs} = create_user()

      assert {:error, :invalid_credentials} =
               Auth.get_user_by_email_and_password(attrs.email, "WrongPassword!")
    end

    test "returns error with nonexistent email" do
      assert {:error, :invalid_credentials} =
               Auth.get_user_by_email_and_password("nobody@example.com", valid_password())
    end
  end

  describe "get_user_by_email_or_username_and_password/3" do
    test "authenticates via email" do
      {user, attrs} = create_user()

      assert {:ok, found} =
               Auth.get_user_by_email_or_username_and_password(attrs.email, attrs.password)

      assert found.uuid == user.uuid
    end

    test "authenticates via username" do
      {user, _attrs} = create_user(%{username: "authuser_login"})

      assert {:ok, found} =
               Auth.get_user_by_email_or_username_and_password("authuser_login", valid_password())

      assert found.uuid == user.uuid
    end

    test "returns error for wrong password via email" do
      {_user, attrs} = create_user()

      assert {:error, :invalid_credentials} =
               Auth.get_user_by_email_or_username_and_password(attrs.email, "WrongPass!")
    end

    test "returns error for wrong password via username" do
      {_user, _attrs} = create_user(%{username: "authuser_wrongpw"})

      assert {:error, :invalid_credentials} =
               Auth.get_user_by_email_or_username_and_password("authuser_wrongpw", "WrongPass!")
    end

    test "returns error for nonexistent identifier" do
      assert {:error, :invalid_credentials} =
               Auth.get_user_by_email_or_username_and_password("ghost@example.com", "SomePass!")
    end

    test "inactive user can still authenticate" do
      # First user is Owner, second is regular User
      {_owner, _} = create_user()
      {user, attrs} = create_user()

      # Deactivate the regular user (not the Owner)
      {:ok, _} = Auth.update_user_status(user, %{is_active: false})

      assert {:ok, found} =
               Auth.get_user_by_email_or_username_and_password(attrs.email, attrs.password)

      assert found.uuid == user.uuid
    end
  end

  describe "session tokens" do
    test "generate_user_session_token/1 creates retrievable token" do
      {user, _} = create_user()

      token = Auth.generate_user_session_token(user)
      assert is_binary(token)

      found = Auth.get_user_by_session_token(token)
      assert found.uuid == user.uuid
    end

    test "invalid token returns nil" do
      assert is_nil(Auth.get_user_by_session_token("invalid_token"))
    end

    test "delete_user_session_token/1 invalidates token" do
      {user, _} = create_user()

      token = Auth.generate_user_session_token(user)
      assert Auth.get_user_by_session_token(token)

      Auth.delete_user_session_token(token)
      assert is_nil(Auth.get_user_by_session_token(token))
    end

    test "delete_all_user_session_tokens/1 logs out everywhere" do
      {user, _} = create_user()

      token1 = Auth.generate_user_session_token(user)
      token2 = Auth.generate_user_session_token(user)

      Auth.delete_all_user_session_tokens(user)

      assert is_nil(Auth.get_user_by_session_token(token1))
      assert is_nil(Auth.get_user_by_session_token(token2))
    end

    test "delete_all_user_session_tokens/1 does not affect other users" do
      {user1, _} = create_user()
      {user2, _} = create_user()

      token1 = Auth.generate_user_session_token(user1)
      token2 = Auth.generate_user_session_token(user2)

      Auth.delete_all_user_session_tokens(user1)

      assert is_nil(Auth.get_user_by_session_token(token1))
      # user2's token should still be valid
      assert Auth.get_user_by_session_token(token2)
    end

    test "get_all_user_session_tokens/1 lists active sessions" do
      {user, _} = create_user()

      Auth.generate_user_session_token(user)
      Auth.generate_user_session_token(user)

      tokens = Auth.get_all_user_session_tokens(user)
      assert length(tokens) == 2
    end
  end

  describe "session fingerprinting" do
    test "stores fingerprint data with token" do
      {user, _} = create_user()

      fingerprint = %{ip_address: "192.168.1.1", user_agent_hash: "testhash123"}

      token = Auth.generate_user_session_token(user, fingerprint: fingerprint)

      record = Auth.get_session_token_record(token)
      assert record.ip_address == "192.168.1.1"
      assert record.user_agent_hash == "testhash123"
    end

    test "token without fingerprint has nil ip_address and user_agent_hash" do
      {user, _} = create_user()

      token = Auth.generate_user_session_token(user)

      record = Auth.get_session_token_record(token)
      assert is_nil(record.ip_address)
      assert is_nil(record.user_agent_hash)
    end
  end
end
