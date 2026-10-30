defmodule PhoenixKit.Users.ManagedOrganizationSessionTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKitWeb.Users.Auth, as: WebAuth

  test "raw and UUID token reads carry session provenance" do
    s = Fixtures.acting_session()
    user = Auth.get_user_by_session_token(s.token)
    assert user.uuid == s.organization.uuid
    assert user.acting_user_uuid == s.person.uuid
    assert user.acting_session_uuid == s.root.uuid
    assert user.organization_manager_uuid == s.manager.uuid
    assert {:ok, scope} = SessionRef.scope_for_session(s.row.uuid, user.uuid)
    assert Scope.acting_user_uuid(scope) == s.person.uuid
    assert Scope.user_email(scope) == "shared@example.com"
    assert Auth.get_user(user.uuid).acting_user_uuid == nil
    assert Scope.acting_user_uuid(nil) == nil
  end

  test "a managed organization without a grant-bound token is anonymous" do
    {token, row} = Fixtures.session(Fixtures.organization())
    assert Auth.get_user_by_session_token(token) == nil
    assert {:error, :session_gone} = SessionRef.scope_for_session(row.uuid, row.user_uuid)
    {ordinary_token, _} = Fixtures.session(Fixtures.person())
    assert %User{managed_by_members: false} = Auth.get_user_by_session_token(ordinary_token)
  end

  for {label, attrs} <- [
        {"inactive", %{is_active: false}},
        {"service", %{api_only: true}},
        {"organization", %{account_type: "organization", organization_name: "Other"}}
      ] do
    test "a #{label} person cannot sustain organization access" do
      s = Fixtures.acting_session()
      s.person |> Ecto.Changeset.change(unquote(Macro.escape(attrs))) |> Repo.update!()
      assert Auth.get_user_by_session_token(s.token) == nil

      assert {:error, :session_gone} =
               SessionRef.scope_for_session(s.row.uuid, s.organization.uuid)
    end
  end

  test "expired and non-session parents are refused" do
    s = Fixtures.acting_session()
    old = DateTime.utc_now() |> DateTime.add(-61 * 86_400, :second) |> DateTime.truncate(:second)
    s.root |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()
    assert Auth.get_user_by_session_token(s.token) == nil

    s.root |> Ecto.Changeset.change(context: "reset_password") |> Repo.update!()
    assert Auth.get_user_by_session_token(s.token) == nil
  end

  test "a grant for another organization or person cannot authorize the token" do
    s = Fixtures.acting_session()
    other_org = Fixtures.organization()
    other_grant = Fixtures.manager(other_org, s.person)

    Repo.update_all(from(t in UserToken, where: t.uuid == ^s.row.uuid),
      set: [organization_manager_uuid: other_grant.uuid]
    )

    assert Auth.get_user_by_session_token(s.token) == nil

    other_grant = Fixtures.manager(s.organization, Fixtures.person())

    Repo.update_all(from(t in UserToken, where: t.uuid == ^s.row.uuid),
      set: [organization_manager_uuid: other_grant.uuid]
    )

    assert Auth.get_user_by_session_token(s.token) == nil
  end

  test "a person's token carrying organization provenance is refused" do
    s = Fixtures.acting_session()

    {token, _} =
      Fixtures.session(s.person, %{
        acting_session_uuid: s.root.uuid,
        organization_manager_uuid: s.manager.uuid
      })

    assert Auth.get_user_by_session_token(token) == nil
  end

  test "root deletion cascades to the acting token" do
    s = Fixtures.acting_session()
    Repo.delete!(s.root)
    assert Repo.get(UserToken, s.row.uuid) == nil
    assert Auth.get_user_by_session_token(s.token) == nil
  end

  test "removal and regrant never revive an old organization token" do
    s = Fixtures.acting_session()
    Repo.delete!(s.manager)
    assert Repo.get(UserToken, s.row.uuid) == nil
    grant = Fixtures.manager(s.organization, s.person)
    refute grant.uuid == s.manager.uuid
    assert Auth.get_user_by_session_token(s.token) == nil
    assert %OrganizationManager{} = grant
  end

  test "embedded identity requires its own matching, live session and retains attribution" do
    s = Fixtures.acting_session()

    embedded = fn session ->
      WebAuth.assign_embedded_current_user(%Phoenix.LiveView.Socket{}, session)
    end

    session = %{"current_user_uuid" => s.organization.uuid, "user_token" => s.token}
    socket = embedded.(session)
    assert socket.assigns.phoenix_kit_current_user.acting_user_uuid == s.person.uuid
    assert socket.assigns.phoenix_kit_session_token == s.token
    assert embedded.(Map.delete(session, "user_token")).assigns.phoenix_kit_current_user == nil

    assert embedded.(%{session | "user_token" => s.root_token}).assigns.phoenix_kit_current_user ==
             nil

    Repo.delete!(s.manager)
    assert embedded.(session).assigns.phoenix_kit_current_user == nil
  end

  test "ordinary embedded identities retain UUID-only support" do
    person = Fixtures.person()

    socket =
      WebAuth.assign_embedded_current_user(%Phoenix.LiveView.Socket{}, %{
        "current_user_uuid" => person.uuid
      })

    assert socket.assigns.phoenix_kit_current_user.uuid == person.uuid
  end
end
