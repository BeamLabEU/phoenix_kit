defmodule PhoenixKit.Integration.Users.PasskeysTest do
  @moduledoc """
  `PhoenixKit.Users.Passkeys` against a software authenticator
  (`PhoenixKit.Test.SoftAuthenticator`): real keys, real CBOR, real signatures, so
  `Wax`'s verification runs for real.

  `async: false`: the tests switch `passkey_login_enabled`.
  """
  use PhoenixKit.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.SoftAuthenticator
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Passkey
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Passkeys

  setup do
    {:ok, _} = Settings.update_setting("passkey_login_enabled", "true")
    on_exit(fn -> Settings.update_setting("passkey_login_enabled", "false") end)
    :ok
  end

  defp user(attrs \\ %{}) do
    email = "passkey_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    # Confirmed: mail nobody asked for goes only to a proven address
    # (`Auth.unsolicited_mail_allowed?/1`).
    {:ok, user} = Auth.admin_confirm_user(user)

    if attrs == %{},
      do: user,
      else: user |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  # A session token as a fresh sign-in leaves it.
  defp fresh(user),
    do: [impersonated: false, session_token: Auth.generate_user_session_token(user)]

  defp add_passkey(user, auth \\ SoftAuthenticator.new()) do
    {challenge, options} = Passkeys.registration_options(user)

    {:ok, passkey} =
      Passkeys.register(user, challenge, SoftAuthenticator.attest(auth, options), fresh(user))

    {auth, passkey}
  end

  defp sign_in(auth, user_uuid, opts \\ []) do
    {challenge, options} = Passkeys.authentication_options()
    Passkeys.authenticate(challenge, SoftAuthenticator.assert(auth, options, user_uuid, opts))
  end

  describe "adding a passkey" do
    test "stores the public key, the domain and a name from the browser" do
      user = user()
      {_auth, passkey} = add_passkey(user)

      assert passkey.user_uuid == user.uuid
      assert passkey.rp_id == Passkeys.relying_party().rp_id
      assert passkey.name == "Chrome on macOS"
      assert passkey.backup_eligible
      assert passkey.transports == ["internal", "hybrid"]

      assert {:ok, %{3 => -7, -2 => <<_::binary-size(32)>>}} =
               Passkey.decode_public_key(passkey.public_key)

      assert Passkeys.usable?(passkey)
    end

    test "tells the person by email, in the inbox and in the activity" do
      user = user()
      add_passkey(user)

      assert_email_sent(fn email ->
        assert email.subject == "A passkey was added to your account"
        assert email.text_body =~ "Chrome on macOS"
      end)

      assert PhoenixKit.Activity.count(action: "user.passkey_added", actor_uuid: user.uuid) == 1
    end

    test "the same passkey cannot be saved twice" do
      user = user()
      {auth, _} = add_passkey(user)
      {challenge, options} = Passkeys.registration_options(user)

      assert {:error, :already_registered} =
               Passkeys.register(
                 user,
                 challenge,
                 SoftAuthenticator.attest(auth, options),
                 fresh(user)
               )
    end

    test "the browser is told which passkeys the person already has" do
      user = user()
      {auth, _} = add_passkey(user)
      {_challenge, options} = Passkeys.registration_options(user)

      assert [%{"id" => id, "type" => "public-key"}] = options["excludeCredentials"]
      assert Base.url_decode64!(id, padding: false) == auth.credential_id
      assert options["authenticatorSelection"]["userVerification"] == "required"
      assert options["authenticatorSelection"]["residentKey"] == "required"
    end

    test "is refused from an impersonated session, and when nobody said" do
      user = user()
      {challenge, options} = Passkeys.registration_options(user)
      params = SoftAuthenticator.attest(SoftAuthenticator.new(), options)
      token = Auth.generate_user_session_token(user)

      assert {:error, :impersonated} =
               Passkeys.register(user, challenge, params,
                 impersonated: true,
                 session_token: token
               )

      assert {:error, :impersonated} =
               Passkeys.register(user, challenge, params, session_token: token)

      assert Passkeys.list(user) == []
    end

    test "is refused from a sign-in older than the window" do
      user = user()
      token = Auth.generate_user_session_token(user)
      old = DateTime.utc_now() |> DateTime.add(-(Passkeys.fresh_session_minutes() + 1), :minute)
      Repo.update_all(from(t in UserToken, where: t.token == ^token), set: [inserted_at: old])

      {challenge, options} = Passkeys.registration_options(user)
      params = SoftAuthenticator.attest(SoftAuthenticator.new(), options)

      assert {:error, :stale_session} =
               Passkeys.register(user, challenge, params,
                 impersonated: false,
                 session_token: token
               )
    end

    test "is refused with another person's session token" do
      user = user()
      other_token = Auth.generate_user_session_token(user())
      {challenge, options} = Passkeys.registration_options(user)
      params = SoftAuthenticator.attest(SoftAuthenticator.new(), options)

      assert {:error, :stale_session} =
               Passkeys.register(user, challenge, params,
                 impersonated: false,
                 session_token: other_token
               )
    end

    test "is refused for a service user and while switched off" do
      service = user(%{api_only: true})
      assert {:error, :not_allowed} = Passkeys.check_may_add(service, fresh(service))

      user = user()
      opts = fresh(user)
      {:ok, _} = Settings.update_setting("passkey_login_enabled", "false")
      assert {:error, :disabled} = Passkeys.check_may_add(user, opts)
    end

    test "is refused for an answer to another site, another kind of request, or no verification" do
      user = user()

      for bend <- [
            [origin: "https://evil.example"],
            [rp_id: "evil.example"],
            [type: "webauthn.get"],
            [user_verified: false],
            [challenge: Base.url_encode64("not the challenge", padding: false)]
          ] do
        {challenge, options} = Passkeys.registration_options(user)
        params = SoftAuthenticator.attest(SoftAuthenticator.new(), options, bend)

        assert {:error, :invalid} = Passkeys.register(user, challenge, params, fresh(user)),
               inspect(bend)
      end

      assert Passkeys.list(user) == []
    end
  end

  describe "signing in" do
    test "a passkey signs its owner in and records the use" do
      user = user()
      {auth, passkey} = add_passkey(user)

      assert {:ok, %User{uuid: uuid}} = sign_in(auth, user.uuid, sign_count: 3)
      assert uuid == user.uuid

      used = Repo.get!(Passkey, passkey.uuid)
      assert used.sign_count == 3
      assert used.last_used_at
    end

    test "the options name no passkey: the device offers its own" do
      {_challenge, options} = Passkeys.authentication_options()

      assert options["allowCredentials"] == []
      assert options["userVerification"] == "required"
      assert options["rpId"] == Passkeys.relying_party().rp_id
    end

    test "every refusal is the same answer" do
      user = user()
      {auth, _} = add_passkey(user)

      for bend <- [
            [origin: "https://evil.example"],
            [rp_id: "evil.example"],
            [type: "webauthn.create"],
            [user_verified: false],
            [user_handle: Passkeys.user_handle(user().uuid)],
            [challenge: Base.url_encode64("not the challenge", padding: false)]
          ] do
        assert {:error, :invalid} = sign_in(auth, user.uuid, bend), inspect(bend)
      end

      # A passkey this site never saw.
      assert {:error, :invalid} = sign_in(SoftAuthenticator.new(), user.uuid)
    end

    test "a forged signature is refused" do
      user = user()
      {auth, _} = add_passkey(user)
      {challenge, options} = Passkeys.authentication_options()
      params = SoftAuthenticator.assert(auth, options, user.uuid)

      forged =
        SoftAuthenticator.assert(
          %{auth | private_key: SoftAuthenticator.new().private_key},
          options,
          user.uuid
        )

      assert {:error, :invalid} =
               Passkeys.authenticate(challenge, %{params | "signature" => forged["signature"]})
    end

    test "a passkey made for the site's old domain signs nobody in" do
      user = user()
      {auth, passkey} = add_passkey(user)
      passkey |> Ecto.Changeset.change(rp_id: "old.example") |> Repo.update!()

      assert {:error, :invalid} = sign_in(auth, user.uuid)
      refute Passkeys.usable?(Repo.get!(Passkey, passkey.uuid))
    end

    test "an in-flight challenge expires when the site's domain changes" do
      user = user()
      {auth, _passkey} = add_passkey(user)
      {challenge, options} = Passkeys.authentication_options()

      {:ok, _} = Settings.update_setting("site_url", "https://new.example")

      assert {:error, :invalid} =
               Passkeys.authenticate(
                 challenge,
                 SoftAuthenticator.assert(auth, options, user.uuid)
               )

      {_challenge, new_options} = Passkeys.registration_options(user)
      assert new_options["rp"]["id"] == "new.example"
      assert new_options["excludeCredentials"] == []
    end

    test "a deactivated person, a service user or a managed organization is refused" do
      for attrs <- [
            %{is_active: false},
            %{api_only: true},
            %{account_type: "organization", managed_by_members: true}
          ] do
        user = user()
        {auth, _} = add_passkey(user)
        user |> Ecto.Changeset.change(attrs) |> Repo.update!()

        assert {:error, :invalid} = sign_in(auth, user.uuid), inspect(attrs)
      end
    end

    test "nothing signs in while switched off" do
      user = user()
      {auth, _} = add_passkey(user)
      {:ok, _} = Settings.update_setting("passkey_login_enabled", "false")

      assert {:error, :invalid} = sign_in(auth, user.uuid)
    end

    test "a signature count that does not go up is recorded, not refused" do
      user = user()
      {auth, passkey} = add_passkey(user)
      assert {:ok, _} = sign_in(auth, user.uuid, sign_count: 10)

      assert {:ok, _} = sign_in(auth, user.uuid, sign_count: 5)
      assert Repo.get!(Passkey, passkey.uuid).sign_count == 10

      assert PhoenixKit.Activity.count(
               action: "user.passkey_sign_count_regressed",
               actor_uuid: user.uuid
             ) == 1
    end

    test "synced passkeys always reporting 0 are not a regression" do
      user = user()
      {auth, _} = add_passkey(user)
      assert {:ok, _} = sign_in(auth, user.uuid)
      assert {:ok, _} = sign_in(auth, user.uuid)

      assert PhoenixKit.Activity.count(
               action: "user.passkey_sign_count_regressed",
               actor_uuid: user.uuid
             ) == 0
    end

    test "garbage is refused without raising" do
      {challenge, _options} = Passkeys.authentication_options()

      for params <- [%{}, %{"rawId" => "%%%"}, %{"rawId" => String.duplicate("A", 20_000)}] do
        assert {:error, :invalid} = Passkeys.authenticate(challenge, params)
      end
    end
  end

  describe "the one-time sign-in token" do
    test "works once" do
      user = user()
      {:ok, token} = Passkeys.mint_login_token(user)

      assert {:ok, %User{uuid: uuid}} = Passkeys.consume_login_token(token)
      assert uuid == user.uuid
      assert :error = Passkeys.consume_login_token(token)
    end

    test "expires after a minute" do
      user = user()
      {:ok, token} = Passkeys.mint_login_token(user)
      old = DateTime.utc_now() |> DateTime.add(-61, :second)

      Repo.update_all(from(t in UserToken, where: t.context == "passkey_login"),
        set: [inserted_at: old]
      )

      assert :error = Passkeys.consume_login_token(token)
    end

    test "none for an account deleted since it was verified" do
      user = user()
      Repo.delete!(user)

      assert :error = Passkeys.mint_login_token(user)
    end

    test "a new one replaces the person's earlier one, and only its hash is stored" do
      user = user()
      {:ok, first} = Passkeys.mint_login_token(user)
      {:ok, second} = Passkeys.mint_login_token(user)

      assert :error = Passkeys.consume_login_token(first)

      assert [%UserToken{token: stored}] =
               Repo.all(from t in UserToken, where: t.context == "passkey_login")

      refute stored == Base.url_decode64!(second, padding: false)
      assert {:ok, _} = Passkeys.consume_login_token(second)
    end

    test "a person deactivated in between is refused" do
      user = user()
      {:ok, token} = Passkeys.mint_login_token(user)
      user |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      assert :error = Passkeys.consume_login_token(token)
    end

    test "garbage is refused" do
      assert :error = Passkeys.consume_login_token("not base64 ~~~")
      assert :error = Passkeys.consume_login_token(nil)
    end
  end

  describe "removing" do
    test "the owner removes their own, and is told" do
      user = user()
      {_auth, passkey} = add_passkey(user)

      assert_email_sent(fn email -> assert email.subject =~ "added" end)

      assert {:ok, _} = Passkeys.delete(user, passkey.uuid, user)
      assert Passkeys.list(user) == []

      assert_email_sent(fn email ->
        assert email.subject == "A passkey was removed from your account"
        assert email.text_body =~ "Removed by: You"
      end)
    end

    test "someone without rank over the owner cannot" do
      user = user()
      {_auth, passkey} = add_passkey(user)

      assert {:error, :not_allowed} = Passkeys.delete(user, passkey.uuid, user())
      assert [_] = Passkeys.list(user)
    end

    test "an administrator can, and the owner hears it was not them" do
      user = user()
      {_auth, passkey} = add_passkey(user)
      {admin, _token} = PhoenixKitWeb.ConnCase.create_admin_user()
      assert_email_sent(fn email -> assert email.subject =~ "added" end)

      assert {:ok, _} = Passkeys.delete(user, passkey.uuid, admin)

      assert_email_sent(fn email ->
        assert email.subject == "A passkey was removed from your account"
        assert email.text_body =~ "Removed by: An administrator"
      end)

      assert PhoenixKit.Activity.count(action: "user.passkey_removed", actor_uuid: admin.uuid) ==
               1
    end

    test "another person's passkey is not found through your account" do
      owner = user()
      {_auth, passkey} = add_passkey(owner)
      other = user()

      assert {:error, :not_found} = Passkeys.delete(other, passkey.uuid, other)
      assert {:error, :not_found} = Passkeys.rename(other, passkey.uuid, "Mine")
    end
  end

  test "renaming trims and limits the name" do
    user = user()
    {_auth, passkey} = add_passkey(user)

    assert {:ok, %Passkey{name: "Work laptop"}} =
             Passkeys.rename(user, passkey.uuid, "  Work laptop ")

    assert {:error, %Ecto.Changeset{}} = Passkeys.rename(user, passkey.uuid, "   ")

    assert {:error, %Ecto.Changeset{}} =
             Passkeys.rename(user, passkey.uuid, String.duplicate("x", 101))
  end

  test "the public key survives its CBOR round trip" do
    key = %{1 => 2, 3 => -7, -1 => 1, -2 => <<1, 2, 3>>, -3 => <<4, 5, 6>>}
    assert {:ok, ^key} = key |> Passkey.encode_public_key() |> Passkey.decode_public_key()
    assert :error = Passkey.decode_public_key(<<255, 0, 1>>)
  end
end
