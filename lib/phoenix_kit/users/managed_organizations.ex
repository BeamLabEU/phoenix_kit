defmodule PhoenixKit.Users.ManagedOrganizations do
  @moduledoc """
  Managed-account creation and conversion for own-account administrators.

  `create/3`, `convert_to_managed/3` and `convert_to_independent/3` take an
  `Actor` made from a trusted signed session, recheck an Owner/Admin's own live
  session and lock current database state. The `host_*` functions below are the
  same operations for a host application. Creation never uses registration or
  the first-user Owner bootstrap.

  ## Host application calls

  `host_create/3`, `host_convert_to_managed/3` and `host_convert_to_independent/3`
  are the same operations for a host application that has its own screens or
  API (and so no browser session to build an `Actor` from).

  **The host checks who may do this; the core does not.** `created_by` is the
  person on whose behalf the host acts, and the core only records it, the way
  `PhoenixKit.Users.Auth.admin_create_user/2` records its actor:
  `host_create/3` writes it as the organization's `created_by_uuid`; every
  `host_*` function records it as the granting person of a new grant and as the
  actor of the activity entries, which carry `"via" => "host"`. The conversions
  do not change `created_by_uuid`. It is re-read under `FOR KEY SHARE` and must
  be an active person that is neither a managed organization nor a service
  user, else the call fails with `{:error, :forbidden}`. That lock excludes a
  concurrent delete or key change; `is_active` is as of the read (a concurrent
  deactivation is not serialized with the call, as with `Actor.admin/1`). Never
  pass a value taken from request parameters.

  Everything else is shared with the `Actor` functions: the lock order (person,
  organization, users), the organization checks (`:organization_policy_mismatch`,
  `:managed_organization_role_not_allowed`), the first manager's eligibility
  (`:manager_must_be_active_person`), credential revocation on conversion,
  referrals and the notification to the manager. The functions that bring an
  organization into the managed state (`host_create/3`, `host_convert_to_managed/3`)
  answer `{:error, :organization_accounts_disabled}` while the
  `enable_organization_accounts` setting is off; the way back
  (`host_convert_to_independent/3`) does not depend on it.

  They join an outer `Repo.transaction/1` of the host, and an error rolls that
  transaction back too.

  ### The first manager of `host_convert_to_managed/3`

  `first_manager` is the uuid of an existing person, or a function of no
  arguments returning `{:ok, person_uuid}` or `{:error, reason}`. The function
  exists for an organization whose login email is the email of the person who
  should manage it: that address is only free after the organization has been
  converted, and the person cannot exist before it. It is called inside the
  transaction, after the organization has given up its email, while the
  organization row is held `FOR NO KEY UPDATE`, `created_by` is held
  `FOR KEY SHARE` and the organization's credentials are already revoked: keep
  it to inserting the person (no mail, HTTP or other locks — send a
  confirmation after the commit). Contract:

    * It creates a **new** person. To use an existing person pass the uuid:
      locking an existing person after the organization would invert the lock
      order (person, organization) the grant functions rely on. The core
      guards against a found person with a heuristic, not a proof: the
      returned row must carry this transaction's id (`xmin`), a command id
      later than the organization's write before the call (`cmin`), and an
      `inserted_at` no earlier than the transaction began (an application-clock
      value compared with the database clock, so a host clock running behind
      the database can refuse a genuinely new person; do not set `inserted_at`
      by hand). Otherwise the call fails with `{:error, :invalid_first_manager}`.
      The check cannot tell an insert from an update by this transaction, so
      the "new person only" rule is the host's to keep. A function that opens
      a savepoint of its own writes under another transaction id and fails
      the check.
    * The core then takes the person's lock and row lock and validates the
      person as for any first manager.
    * `{:error, reason}` is returned as it is, so an `Ecto.Changeset` of the
      person reaches the host to show against its form fields. Anything else
      the function returns is `{:error, :invalid_first_manager}`.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
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
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  def create(actor, attrs, first_manager_uuid) do
    Revocation.transaction(fn ->
      Locks.person!(first_manager_uuid)
      Locks.users!([first_manager_uuid])
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.admin() |> Locks.value!()
      insert_organization!(attrs, first_manager_uuid, authority)
    end)
  end

  @doc "Host-application form of `create/3`; see the module documentation."
  def host_create(attrs, first_manager_uuid, %User{} = created_by) do
    Revocation.transaction(fn ->
      require_accounts_enabled!()
      Locks.person!(first_manager_uuid)
      Locks.users!([first_manager_uuid])
      authority = Actor.host!(created_by)
      insert_organization!(attrs, first_manager_uuid, authority)
    end)
  end

  defp insert_organization!(attrs, first_manager_uuid, authority) do
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
  end

  def convert_to_managed(actor, organization_uuid, first_manager_uuid) do
    Revocation.transaction(fn ->
      Locks.person!(first_manager_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([first_manager_uuid])
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.admin() |> Locks.value!()
      make_managed!(org, authority, fn _org -> first_manager_uuid end)
    end)
  end

  @doc """
  Host-application form of `convert_to_managed/3`; see the module documentation.

  `first_manager` is a person uuid, or a function creating the new person
  (`fn -> {:ok, person_uuid} | {:error, reason} end`).
  """
  def host_convert_to_managed(organization_uuid, first_manager, %User{} = created_by)
      when is_function(first_manager, 0) do
    Revocation.transaction(fn ->
      require_accounts_enabled!()
      org = Locks.organization!(organization_uuid)
      authority = Actor.host!(created_by)
      make_managed!(org, authority, &create_first_manager!(&1, first_manager))
    end)
  end

  def host_convert_to_managed(organization_uuid, first_manager_uuid, %User{} = created_by) do
    Revocation.transaction(fn ->
      require_accounts_enabled!()
      Locks.person!(first_manager_uuid)
      org = Locks.organization!(organization_uuid)
      Locks.users!([first_manager_uuid])
      authority = Actor.host!(created_by)
      make_managed!(org, authority, fn _org -> first_manager_uuid end)
    end)
  end

  # `resolve_manager` runs once the organization has given up its email and
  # returns the uuid to grant; it holds the person's locks by then.
  defp make_managed!(org, authority, resolve_manager) do
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
    OrganizationManagers.insert_locked(org, resolve_manager.(org), authority)
    org
  end

  defp create_first_manager!(org, fun) do
    started = write_stamp!(org.uuid)

    person_uuid =
      case fun.() do
        {:ok, uuid} -> uuid
        {:error, reason} -> RepoHelper.repo().rollback(reason)
        _ -> RepoHelper.repo().rollback(:invalid_first_manager)
      end

    unless UUIDUtils.valid?(person_uuid) and new_in_transaction?(person_uuid, started),
      do: RepoHelper.repo().rollback(:invalid_first_manager)

    Locks.person!(person_uuid)
    Locks.users!([person_uuid])
    person_uuid
  end

  # What a row's own transaction-id and command-id say about its last write:
  # a person written by the same transaction (id) after `started` (command id)
  # was created by the function, not found by it.
  defp write_stamp!(uuid) do
    from(u in User,
      where: u.uuid == ^uuid,
      select: {fragment("?.xmin::text", u), fragment("?.cmin::text::bigint", u)}
    )
    |> RepoHelper.repo().one!()
  end

  defp new_in_transaction?(uuid, {xmin, cmin}) do
    from(u in User,
      where: u.uuid == ^uuid and u.account_type == "person",
      where: fragment("?.xmin::text", u) == ^xmin,
      where: fragment("?.cmin::text::bigint", u) > ^cmin,
      where: u.inserted_at >= fragment("date_trunc('second', now() AT TIME ZONE 'UTC')")
    )
    |> RepoHelper.repo().exists?()
  end

  def convert_to_independent(actor, organization_uuid, attrs) do
    Revocation.transaction(fn ->
      org = Locks.organization!(organization_uuid)
      Locks.users!([Actor.person_uuid(actor)], "FOR KEY SHARE")
      authority = actor |> Actor.admin() |> Locks.value!()
      make_independent!(org, attrs, authority)
    end)
  end

  @doc "Host-application form of `convert_to_independent/3`; see the module documentation."
  def host_convert_to_independent(organization_uuid, attrs, %User{} = created_by) do
    Revocation.transaction(fn ->
      org = Locks.organization!(organization_uuid)
      authority = Actor.host!(created_by)
      make_independent!(org, attrs, authority)
    end)
  end

  defp make_independent!(org, attrs, authority) do
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

  defp require_accounts_enabled! do
    unless Auth.organization_accounts_enabled?(),
      do: RepoHelper.repo().rollback(:organization_accounts_disabled)
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
