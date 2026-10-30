defmodule PhoenixKit.Users.ManagedOrganizations do
  @moduledoc """
  Managed-account creation and conversion for own-account administrators.

  Every call takes an `Actor` made from a trusted signed session,
  rechecks an Owner/Admin's own live session and locks current database state.
  Creation never uses registration or the first-user Owner bootstrap.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.ManagedOrganizations.Locks
  alias PhoenixKit.Users.OAuthProvider
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions.Revocation

  def create(actor, attrs, first_manager_uuid) do
    Revocation.transaction(fn ->
      Locks.person!(first_manager_uuid)
      Locks.users!([first_manager_uuid])
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.admin() |> Locks.value!()
      uuid = UUIDv7.generate()

      org =
        %User{uuid: uuid}
        |> creation_changeset(attrs, authority.person_uuid)
        |> RepoHelper.repo().insert()
        |> Locks.value!()

      org = org |> Referrals.mark_satisfied("managed_organization") |> Locks.value!()
      org |> Roles.assign_role("User", authority.scope.user, broadcast: false) |> Locks.value!()
      OrganizationManagers.insert_locked(org, first_manager_uuid, authority)
      org
    end)
  end

  def convert_to_managed(actor, organization_uuid, first_manager_uuid) do
    Revocation.transaction(fn ->
      Locks.person!(first_manager_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([first_manager_uuid])
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.admin() |> Locks.value!()
      require_policy!(org, false)
      require_permitted_roles!(org)
      revoke_credentials!(org, authority.person_uuid)

      contact_email = if org.contact_email in [nil, ""], do: org.email, else: org.contact_email

      org =
        org
        |> User.contact_email_changeset(%{contact_email: contact_email})
        |> change(managed_fields(org.uuid))
        |> RepoHelper.repo().update()
        |> Locks.value!()

      org = org |> Referrals.mark_satisfied("managed_organization") |> Locks.value!()
      OrganizationManagers.insert_locked(org, first_manager_uuid, authority)
      org
    end)
  end

  def convert_to_independent(actor, organization_uuid, attrs) do
    Revocation.transaction(fn ->
      org = Locks.organization!(organization_uuid)
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.admin() |> Locks.value!()
      require_policy!(org, true)
      # Lifting the ceiling must not reactivate an illicit direct assignment
      # or API permissions a custom role acquired while this account was managed.
      require_permitted_roles!(org)

      # Validate the NEW credentials through the ordinary email/password rules.
      # The temporary data policy is only for validation; force_change persists
      # the actual policy transition even though the validation data says false.
      changeset =
        %{org | managed_by_members: false}
        |> User.email_changeset(attrs)
        |> User.password_changeset(attrs)
        |> force_change(:managed_by_members, false)
        |> put_change(:confirmed_at, nil)
        |> put_change(:google_email, nil)

      unless changeset.valid?, do: RepoHelper.repo().rollback(changeset)

      # Drain BEFORE clearing policy: a surviving acting token would otherwise
      # become an ordinary session. No old password, provider or key returns.
      revoke_credentials!(org, authority.person_uuid)

      OrganizationManagers.clear_locked(org, authority)

      RepoHelper.repo().update_all(
        from(i in OrganizationInvitation,
          where: i.organization_uuid == ^org.uuid and i.kind == :manager and i.status == :pending
        ),
        set: [status: :cancelled, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      changeset |> RepoHelper.repo().update() |> Locks.value!()
    end)
  end

  defp creation_changeset(user, attrs, actor_uuid) do
    # A narrow cast: no login email/password, flags, roles, custom fields or
    # employment relationship can be supplied by the form/CRM caller.
    user
    |> cast(attrs, [:organization_name, :contact_email])
    |> validate_required([:organization_name])
    |> validate_length(:organization_name, max: 255)
    |> User.contact_email_changeset(attrs)
    |> change(managed_fields(user.uuid))
    |> put_change(:account_type, "organization")
    |> put_change(:created_by_uuid, actor_uuid)
    |> unique_constraint(:email)
  end

  defp managed_fields(uuid) do
    [
      managed_by_members: true,
      email: "org-#{uuid}@organization.invalid",
      hashed_password: Bcrypt.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(32))),
      google_email: nil,
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    ]
  end

  defp require_policy!(
         %User{managed_by_members: expected, api_only: false, is_active: true},
         expected
       ),
       do: :ok

  defp require_policy!(_, _), do: RepoHelper.repo().rollback(:organization_policy_mismatch)

  defp require_permitted_roles!(org) do
    Enum.each(Roles.get_user_role_records(org), fn role ->
      if Scope.managed_ceiling_role?(role.name),
        do: RepoHelper.repo().rollback(:managed_organization_role_not_allowed)

      keys =
        role.uuid |> to_string() |> Permissions.fetch_permissions_for_role() |> Locks.value!()

      if Enum.any?(keys, &Scope.managed_ceiling_key?/1),
        do: RepoHelper.repo().rollback(:managed_organization_role_not_allowed)
    end)
  end

  defp revoke_credentials!(org, actor_uuid) do
    repo = RepoHelper.repo()
    Revocation.delete_all(UserToken.by_user_and_contexts_query(org, :all))
    repo.delete_all(from(p in OAuthProvider, where: p.user_uuid == ^org.uuid))

    from(k in Key, where: k.user_uuid == ^org.uuid, order_by: k.uuid, lock: "FOR UPDATE")
    |> repo.all()
    |> Enum.each(fn key -> key |> Keys.revoke(actor_uuid) |> Locks.value!() end)
  end
end
