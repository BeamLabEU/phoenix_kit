defmodule PhoenixKit.Test.ManagedOrganizationFixtures do
  @moduledoc false

  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Roles

  def person(attrs \\ %{}) do
    %User{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          email: "manager-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("ValidPassword123!"),
          confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
    |> Repo.insert!()
    |> with_user_role()
  end

  def organization(attrs \\ %{}) do
    uuid = UUIDv7.generate()

    person(
      Map.merge(
        %{
          uuid: uuid,
          email: "org-#{uuid}@organization.invalid",
          account_type: "organization",
          organization_name: "Acme",
          managed_by_members: true,
          contact_email: "shared@example.com"
        },
        attrs
      )
    )
  end

  def manager(organization, person) do
    %OrganizationManager{}
    |> OrganizationManager.changeset(%{
      organization_uuid: organization.uuid,
      user_uuid: person.uuid
    })
    |> Repo.insert!()
  end

  def session(user, attrs \\ %{}) do
    {token, row} = UserToken.build_session_token(user)
    row = row |> Ecto.Changeset.change(attrs) |> Repo.insert!()
    {token, row}
  end

  def acting_session do
    person = person()
    organization = organization()
    manager = manager(organization, person)
    {root_token, root} = session(person)

    {token, row} =
      session(organization, %{
        acting_session_uuid: root.uuid,
        organization_manager_uuid: manager.uuid
      })

    %{
      person: person,
      organization: organization,
      manager: manager,
      root_token: root_token,
      root: root,
      token: token,
      row: row
    }
  end

  def email_token(user, context) do
    {token, row} = UserToken.build_email_token(user, context)
    Repo.insert!(row)
    token
  end

  def admin_actor do
    user = person()
    {:ok, _} = Roles.assign_role(user, "Admin")
    {token, _row} = session(user)
    {:ok, actor} = Actor.from_session(%{"user_token" => token})
    {actor, user}
  end

  def acting_actor(s) do
    {:ok, actor} =
      Actor.from_session(%{
        "user_token" => s.token,
        "pk_session_accounts" => [s.root_token]
      })

    actor
  end

  defp with_user_role(user) do
    {:ok, _} = Roles.assign_role(user, "User")
    user
  end
end
