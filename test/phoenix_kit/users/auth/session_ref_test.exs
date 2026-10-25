defmodule PhoenixKit.Users.Auth.SessionRefTest do
  @moduledoc """
  `PhoenixKit.Users.Auth.SessionRef`: the scope of a live browser session, rebuilt from
  the id of its token row and the user it belongs to, and the session reference a
  LiveView reads from its session map.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.API.KeyTestSupport, only: [register_user!: 0, role_with: 1]

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Roles

  defmodule InviteOnly do
    @moduledoc false
    def module_key, do: "referrals"
    def get_config, do: %{enabled: true, required: true}
  end

  defp unconfirmed_user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "session_ref_unconfirmed_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    nil = user.confirmed_at
    user
  end

  defp session!(user) do
    token = Auth.generate_user_session_token(user)
    %UserToken{uuid: uuid} = Auth.get_session_token_record(token)
    {token, uuid}
  end

  defp user_with_roles(roles) do
    user = register_user!()
    for role <- roles, do: {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  describe "scope_for_session/2" do
    test "a live session of an active user gives that user's scope" do
      {role, _} = role_with(["dashboard"])
      user = user_with_roles([role])
      {_token, uuid} = session!(user)

      assert {:ok, %Scope{} = scope} = SessionRef.scope_for_session(uuid, user.uuid)
      assert scope.user.uuid == user.uuid
      assert Scope.can?(scope, "dashboard")
      refute Scope.can?(scope, "settings")
    end

    test "an expired session is gone" do
      user = register_user!()
      {_token, uuid} = session!(user)

      sixty_one_days_ago =
        DateTime.utc_now() |> DateTime.add(-61, :day) |> DateTime.truncate(:second)

      Repo.update_all(from(t in UserToken, where: t.uuid == ^uuid),
        set: [inserted_at: sixty_one_days_ago]
      )

      assert {:error, :session_gone} = SessionRef.scope_for_session(uuid, user.uuid)
    end

    test "a revoked (logged out) session is gone" do
      user = register_user!()
      {token, uuid} = session!(user)

      :ok = Auth.delete_user_session_token(token)

      assert {:error, :session_gone} = SessionRef.scope_for_session(uuid, user.uuid)
    end

    test "a token row of another context is not a session" do
      user = register_user!()
      {_encoded, confirm} = UserToken.build_email_token(user, "confirm")
      %UserToken{uuid: uuid} = Repo.insert!(confirm)

      assert {:error, :session_gone} = SessionRef.scope_for_session(uuid, user.uuid)
    end

    test "another user's session is a mismatch" do
      owner = register_user!()
      other = register_user!()
      {_token, uuid} = session!(owner)

      assert {:error, :mismatch} = SessionRef.scope_for_session(uuid, other.uuid)
    end

    test "the session of a blocked user is inactive" do
      user = register_user!()
      {_token, uuid} = session!(user)

      Repo.update_all(from(u in User, where: u.uuid == ^user.uuid), set: [is_active: false])

      log =
        capture_log(fn ->
          assert {:error, :inactive} = SessionRef.scope_for_session(uuid, user.uuid)
        end)

      assert log =~ "Inactive user #{user.uuid}"
    end

    test "a service user's session row is not a session" do
      user = register_user!()
      {_token, uuid} = session!(user)

      Repo.update_all(from(u in User, where: u.uuid == ^user.uuid), set: [api_only: true])

      assert {:error, :session_gone} = SessionRef.scope_for_session(uuid, user.uuid)
    end

    test "an unconfirmed user is refused while confirmation is required, as on the web" do
      user = unconfirmed_user!()
      {_token, uuid} = session!(user)

      # `require_email_confirmation` is on by default.
      assert {:error, :unconfirmed} = SessionRef.scope_for_session(uuid, user.uuid)

      capture_log(fn ->
        {:ok, _} = Settings.update_boolean_setting("require_email_confirmation", false)
      end)

      assert {:ok, %Scope{}} = SessionRef.scope_for_session(uuid, user.uuid)
    end

    test "an account parked by the invite-only gate is refused, as on the web" do
      user = register_user!()
      {_token, uuid} = session!(user)

      ModuleRegistry.register(InviteOnly)
      on_exit(fn -> ModuleRegistry.unregister(InviteOnly) end)

      capture_log(fn ->
        {:ok, _} = Settings.update_boolean_setting("referral_codes_required", true)
        {:ok, _} = Settings.update_boolean_setting("referral_grandfather_existing", false)
      end)

      assert {:error, :referral_required} = SessionRef.scope_for_session(uuid, user.uuid)

      capture_log(fn ->
        {:ok, _} = Settings.update_boolean_setting("referral_codes_required", false)
      end)

      assert {:ok, %Scope{}} = SessionRef.scope_for_session(uuid, user.uuid)
    end

    test "an unknown or malformed reference is gone, never an exception" do
      user = register_user!()

      assert {:error, :session_gone} = SessionRef.scope_for_session(UUIDv7.generate(), user.uuid)
      assert {:error, :session_gone} = SessionRef.scope_for_session("not-a-uuid", user.uuid)
      assert {:error, :session_gone} = SessionRef.scope_for_session(nil, user.uuid)
      {_token, uuid} = session!(user)
      assert {:error, :mismatch} = SessionRef.scope_for_session(uuid, "not-a-uuid")
      assert {:error, :mismatch} = SessionRef.scope_for_session(uuid, nil)
    end

    test "the session's active role narrows the scope, as on the web" do
      # No settings cache runs here: the write logs that it could not invalidate it.
      capture_log(fn ->
        {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)
      end)

      {reader, _} = role_with(["dashboard"])
      {writer, _} = role_with(["settings"])
      user = user_with_roles([reader, writer])
      {_token, uuid} = session!(user)
      {_token, other_uuid} = session!(user)

      # The session that never switched acts as the default role; the first one switches
      # to the other role.
      assert {:ok, default_scope} = SessionRef.scope_for_session(other_uuid, user.uuid)
      default = Scope.active_role(default_scope)

      [{chosen, permission}, {_other, denied}] =
        Enum.sort_by([{writer, "settings"}, {reader, "dashboard"}], fn {role, _} ->
          role.uuid == default.uuid
        end)

      Repo.update_all(from(t in UserToken, where: t.uuid == ^uuid),
        set: [active_role_uuid: chosen.uuid]
      )

      assert {:ok, scope} = SessionRef.scope_for_session(uuid, user.uuid)
      assert Scope.active_role(scope).uuid == chosen.uuid
      assert Scope.can?(scope, permission)
      refute Scope.can?(scope, denied)

      # The other session is not narrowed by the role the first one chose.
      assert {:ok, other} = SessionRef.scope_for_session(other_uuid, user.uuid)
      assert Scope.active_role(other).uuid == default.uuid
      refute Scope.can?(other, permission)
    end
  end

  describe "scope_for_user/2" do
    test "an active, confirmed user gives the full scope with narrow: false" do
      capture_log(fn ->
        {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)
      end)

      {reader, _} = role_with(["dashboard"])
      {writer, _} = role_with(["settings"])
      user = user_with_roles([reader, writer])

      assert {:ok, %Scope{} = scope} = SessionRef.scope_for_user(user, narrow: false)
      assert scope.user.uuid == user.uuid
      assert Scope.active_role(scope) == nil
      assert Scope.can?(scope, "dashboard")
      assert Scope.can?(scope, "settings")

      # Narrowed (the default), the user acts as one role, as a session that never switched.
      assert {:ok, narrowed} = SessionRef.scope_for_user(user, [])
      assert Scope.active_role(narrowed) != nil
    end

    test "refuses a blocked, an unconfirmed and an invite-parked user as a session would" do
      blocked = %{register_user!() | is_active: false}

      capture_log(fn ->
        assert {:error, :inactive} = SessionRef.scope_for_user(blocked, narrow: false)
      end)

      assert {:error, :unconfirmed} =
               SessionRef.scope_for_user(unconfirmed_user!(), narrow: false)

      parked = register_user!()
      ModuleRegistry.register(InviteOnly)
      on_exit(fn -> ModuleRegistry.unregister(InviteOnly) end)

      capture_log(fn ->
        {:ok, _} = Settings.update_boolean_setting("referral_codes_required", true)
        {:ok, _} = Settings.update_boolean_setting("referral_grandfather_existing", false)
      end)

      assert {:error, :referral_required} = SessionRef.scope_for_user(parked, narrow: false)
    end
  end

  describe "from_session/1" do
    test "the token row's id and its user, from the session's user_token" do
      user = register_user!()
      {token, uuid} = session!(user)

      assert {:ok, {^uuid, user_uuid}} = SessionRef.from_session(%{"user_token" => token})
      assert user_uuid == user.uuid
    end

    test "no token, an unknown token or a dead session gives :error" do
      user = register_user!()
      {token, _uuid} = session!(user)
      :ok = Auth.delete_user_session_token(token)

      assert :error = SessionRef.from_session(%{})
      assert :error = SessionRef.from_session(%{"user_token" => token})
      assert :error = SessionRef.from_session(%{"user_token" => :crypto.strong_rand_bytes(48)})
      assert :error = SessionRef.from_session(%{"user_token" => 42})
    end
  end
end
