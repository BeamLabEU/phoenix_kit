defmodule PhoenixKit.Users.ManagedOrganizationRevocationTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Users.Sessions.Revocation
  alias PhoenixKitWeb.Endpoint

  @new_password "DifferentPassword123!"

  defp watch(s) do
    Endpoint.subscribe(Sessions.live_socket_id(s.root_token))
    Endpoint.subscribe(Sessions.live_socket_id(s.token))
    s
  end

  defp assert_closed(token) do
    topic = Sessions.live_socket_id(token)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  defp refute_closed(token) do
    topic = Sessions.live_socket_id(token)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 30
  end

  for path <- [
        :own_session,
        :admin_session,
        :all_sessions,
        :auth_session,
        :auth_all,
        :admin_password,
        :password_reset,
        :external_confirmation,
        :deactivation,
        :deletion
      ] do
    test "#{path} deletes and disconnects the parent and its organization sessions" do
      s = Fixtures.acting_session() |> watch()
      revoke(unquote(path), s)
      assert Repo.get(UserToken, s.root.uuid) == nil
      assert Repo.get(UserToken, s.row.uuid) == nil
      assert Auth.get_user_by_session_token(s.token) == nil
      assert_closed(s.root_token)
      assert_closed(s.token)
    end
  end

  test "revoking other devices preserves the current parent and its organization session" do
    revoked = Fixtures.acting_session() |> watch()
    {kept_root_token, kept_root} = Fixtures.session(revoked.person)

    {kept_token, kept_row} =
      Fixtures.session(revoked.organization, %{
        acting_session_uuid: kept_root.uuid,
        organization_manager_uuid: revoked.manager.uuid
      })

    Endpoint.subscribe(Sessions.live_socket_id(kept_root_token))
    Endpoint.subscribe(Sessions.live_socket_id(kept_token))

    assert 1 = Sessions.revoke_other_user_sessions(revoked.person, kept_root_token)
    assert_closed(revoked.root_token)
    assert_closed(revoked.token)
    assert Repo.get(UserToken, kept_root.uuid)
    assert Repo.get(UserToken, kept_row.uuid)
    refute_closed(kept_root_token)
    refute_closed(kept_token)
  end

  test "role-specific revocation includes dependent organization sessions" do
    s = Fixtures.acting_session() |> watch()
    role = Roles.get_role_by_name("User")

    Repo.update_all(from(t in UserToken, where: t.uuid == ^s.root.uuid),
      set: [active_role_uuid: role.uuid]
    )

    assert 1 = Sessions.revoke_user_sessions_in_role(s.person, role.uuid)
    assert_closed(s.root_token)
    assert_closed(s.token)
    assert Repo.get(UserToken, s.row.uuid) == nil
  end

  test "the password form exception spares only its own socket, never its dependent organization" do
    s = Fixtures.acting_session() |> watch()

    assert {:ok, _} =
             Auth.update_user_password(s.person, "ValidPassword123!", %{password: @new_password},
               except_token: s.root_token
             )

    assert Repo.get(UserToken, s.root.uuid) == nil
    assert Repo.get(UserToken, s.row.uuid) == nil
    assert_closed(s.token)
    refute_closed(s.root_token)
  end

  test "grant removal closes the organization socket and leaves the person's session alone" do
    s = Fixtures.acting_session() |> watch()

    assert {1, nil} =
             Revocation.delete_manager_grants(
               from(m in OrganizationManager, where: m.uuid == ^s.manager.uuid)
             )

    assert Repo.get(OrganizationManager, s.manager.uuid) == nil
    assert Repo.get(UserToken, s.row.uuid) == nil
    assert Auth.get_user_by_session_token(s.root_token)
    assert_closed(s.token)
    refute_closed(s.root_token)
  end

  test "an owned transaction defers nested drains until its commit" do
    s = Fixtures.acting_session() |> watch()

    assert {:ok, :finished} =
             Revocation.transaction(fn ->
               assert {:ok, :ok} =
                        Revocation.transaction(fn ->
                          assert :ok = Auth.delete_user_session_token(s.root_token)
                          refute_closed(s.root_token)
                          refute_closed(s.token)
                          :ok
                        end)

               refute_closed(s.root_token)
               refute_closed(s.token)
               :finished
             end)

    assert_closed(s.root_token)
    assert_closed(s.token)
  end

  test "rollback preserves sessions and discards the collector before the next call" do
    restored = Fixtures.acting_session() |> watch()

    assert {:error, :undone} =
             Revocation.transaction(fn ->
               Auth.delete_user_session_token(restored.root_token)
               Repo.rollback(:undone)
             end)

    assert Auth.get_user_by_session_token(restored.root_token)
    assert Auth.get_user_by_session_token(restored.token)

    revoked = Fixtures.acting_session() |> watch()
    Auth.delete_user_session_token(revoked.root_token)
    assert_closed(revoked.root_token)
    assert_closed(revoked.token)
    refute_closed(restored.root_token)
    refute_closed(restored.token)
  end

  test "failed password validation deletes nothing and broadcasts nothing" do
    s = Fixtures.acting_session() |> watch()

    assert {:error, _} =
             Auth.update_user_password(s.person, "incorrect", %{password: @new_password})

    assert Auth.get_user_by_session_token(s.root_token)
    assert Auth.get_user_by_session_token(s.token)
    refute_closed(s.root_token)
    refute_closed(s.token)
  end

  defp revoke(:own_session, s), do: :ok = Sessions.revoke_user_session(s.person, s.root.uuid)
  defp revoke(:admin_session, s), do: :ok = Sessions.revoke_session(s.root.uuid, actor: s.person)
  defp revoke(:all_sessions, s), do: 1 = Sessions.revoke_user_sessions(s.person, actor: s.person)
  defp revoke(:auth_session, s), do: :ok = Auth.delete_user_session_token(s.root_token)
  defp revoke(:auth_all, s), do: :ok = Auth.delete_all_user_session_tokens(s.person)

  defp revoke(:admin_password, s),
    do: {:ok, _} = Auth.admin_update_user_password(s.person, %{password: @new_password})

  defp revoke(:password_reset, s),
    do: {:ok, _} = Auth.reset_user_password(s.person, %{password: @new_password})

  defp revoke(:external_confirmation, s) do
    user = s.person |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()
    assert {:ok, _} = Auth.confirm_user_from_external_proof(user)
  end

  defp revoke(:deactivation, s) do
    Fixtures.manager(s.organization, Fixtures.person())
    assert {:ok, _} = Auth.update_user_status(s.person, %{is_active: false})
  end

  defp revoke(:deletion, s) do
    Fixtures.manager(s.organization, Fixtures.person())
    owner = Auth.get_user_by_email("seed-owner@phoenixkit.test")
    assert {:ok, _} = Auth.delete_user(s.person, %{current_user: owner})
  end
end
