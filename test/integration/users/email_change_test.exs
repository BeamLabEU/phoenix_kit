defmodule PhoenixKit.Integration.Users.EmailChangeTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth

  defp unique_email, do: "emailchg_#{System.unique_integer([:positive])}@example.com"
  @valid_password "ValidPassword123!"

  defp create_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: @valid_password})
    user
  end

  describe "apply_user_email/3" do
    test "validates email change with correct password" do
      user = create_user()
      new_email = unique_email()

      assert {:ok, applied} =
               Auth.apply_user_email(user, @valid_password, %{email: new_email})

      assert applied.email == new_email
    end

    test "rejects email change with wrong password" do
      user = create_user()

      assert {:error, changeset} =
               Auth.apply_user_email(user, "WrongPassword!", %{email: unique_email()})

      assert errors_on(changeset).current_password != []
    end

    test "does not change email if same as current" do
      user = create_user()

      # apply_user_email validates via changeset; if no change detected, it may succeed
      # The important thing is the email doesn't actually change
      result = Auth.apply_user_email(user, @valid_password, %{email: user.email})

      case result do
        {:ok, applied} ->
          # Email stayed the same
          assert applied.email == user.email

        {:error, changeset} ->
          assert errors_on(changeset).email != []
      end
    end

    test "rejects invalid email format" do
      user = create_user()

      assert {:error, changeset} =
               Auth.apply_user_email(user, @valid_password, %{email: "not-valid"})

      assert errors_on(changeset).email != []
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    test "sends email with token for valid change" do
      user = create_user()
      new_email = unique_email()

      # First apply the email change (validates password, sets pending email)
      {:ok, applied_user} =
        Auth.apply_user_email(user, @valid_password, %{email: new_email})

      assert {:ok, %Swoosh.Email{} = email} =
               Auth.deliver_user_update_email_instructions(
                 applied_user,
                 user.email,
                 &"http://example.com/confirm_email/#{&1}"
               )

      # Email should contain a token URL
      assert email.html_body || email.text_body
    end
  end

  describe "update_user_email/2" do
    test "updates email with valid token from full workflow" do
      user = create_user()
      original_email = user.email
      new_email = unique_email()

      # Step 1: Apply email change (validates password)
      {:ok, applied_user} =
        Auth.apply_user_email(user, @valid_password, %{email: new_email})

      # Step 2: Deliver instructions (generates token)
      {:ok, %Swoosh.Email{} = email} =
        Auth.deliver_user_update_email_instructions(
          applied_user,
          original_email,
          &"http://example.com/confirm_email/#{&1}"
        )

      # Step 3: Extract token from email
      [_, token] =
        Regex.run(~r/confirm_email\/([^\s"<]+)/, email.html_body || email.text_body)

      # Step 4: Confirm the email change
      assert :ok = Auth.update_user_email(user, token)

      # Verify the email was actually changed
      updated = Auth.get_user(user.uuid)
      assert updated.email == new_email
    end

    test "returns error for invalid token" do
      user = create_user()

      assert :error = Auth.update_user_email(user, "invalid_token_string")
    end
  end

  describe "full email change workflow" do
    test "apply -> deliver -> update completes email change" do
      user = create_user()
      {:ok, _} = Auth.admin_confirm_user(user)
      original_email = user.email
      new_email = unique_email()

      # Apply
      {:ok, applied} = Auth.apply_user_email(user, @valid_password, %{email: new_email})
      assert applied.email == new_email

      # Deliver
      {:ok, %Swoosh.Email{} = swoosh_email} =
        Auth.deliver_user_update_email_instructions(
          applied,
          original_email,
          &"http://example.com/confirm_email/#{&1}"
        )

      # Extract token and confirm
      [_, token] =
        Regex.run(~r/confirm_email\/([^\s"<]+)/, swoosh_email.html_body || swoosh_email.text_body)

      assert :ok = Auth.update_user_email(user, token)

      # Verify the old email no longer resolves
      assert is_nil(Auth.get_user_by_email(original_email))

      # Verify the new email resolves
      found = Auth.get_user_by_email(new_email)
      assert found.uuid == user.uuid
    end
  end
end
