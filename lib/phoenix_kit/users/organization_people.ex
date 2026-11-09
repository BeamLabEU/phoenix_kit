defmodule PhoenixKit.Users.OrganizationPeople do
  @moduledoc """
  An organization's people, from the organization's side: list, find, attach,
  detach and invite. The admin's page of an organization uses it for its quick
  People control (`PhoenixKitWeb.Live.Components.OrganizationPeople`), the
  mirror of a person's Organizations control (`PhoenixKit.Users.PersonOrganizations`).

  It adds no rules of its own. Attaching and detaching go through
  `PersonOrganizations.attach/4` and `detach/4`, so through the functions that
  own each tie and check the actor:

    * a **link** to a managed organization (`OrganizationManagers.add/4`,
      `remove/4`), typed, with what the link lets the person do;
    * the older single tie, `users.organization_uuid`, to an organization with
      a login of its own (`Auth.set_organization/2`,
      `Auth.remove_from_organization/1`). Attaching one replaces any other tie
      the person has.

  Someone who has no account yet is invited by email to a managed organization
  (`Invitations.create_invitation/4`, `kind: :manager`), the analogue of
  creating a company from its name on a person's page.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.PersonOrganizations
  alias PhoenixKit.Users.Role

  @search_limit 8

  @type entry :: %{
          person: User.t(),
          kind: :link | :member,
          type: PhoenixKit.Users.RelationshipType.t() | nil,
          all_roles?: boolean(),
          roles: [Role.t()]
        }

  @doc """
  The organization's people by name: each active person linked to it
  (`kind: :link`, with the type and the roles in effect through the link, the
  base `User` role left out), then the people with the older tie
  (`kind: :member`) who are not linked too.
  """
  @spec list(User.t()) :: [entry()]
  def list(%User{account_type: "organization"} = org) do
    base = Role.system_roles().user

    links =
      for link <- OrganizationManagers.people_of(org.uuid) do
        %{
          person: link.person,
          kind: :link,
          type: link.type,
          all_roles?: link.all_roles?,
          roles: Enum.reject(link.roles, &(&1.name == base))
        }
      end

    linked = MapSet.new(links, & &1.person.uuid)

    members =
      for person <- Auth.list_organization_members(org.uuid),
          not MapSet.member?(linked, person.uuid) do
        %{person: person, kind: :member, type: nil, all_roles?: false, roles: []}
      end

    Enum.sort_by(links ++ members, &String.downcase(User.display_name(&1.person)))
  end

  def list(_account), do: []

  @doc """
  Active people (no organizations, no service users) whose name, email or
  username contains `term`, those starting with it first, leaving out the
  ones in `exclude_uuids`. An empty term lists the first few by email.
  """
  @spec search(String.t(), [String.t()]) :: [User.t()]
  def search(term, exclude_uuids \\ []) when is_binary(term) do
    term = String.trim(term)
    pattern = "%" <> escape_like(term) <> "%"
    prefix = escape_like(term) <> "%"

    from(u in User,
      where:
        u.account_type == "person" and u.is_active and not u.api_only and
          not u.managed_by_members,
      where: u.uuid not in ^exclude_uuids,
      where:
        ilike(u.email, ^pattern) or ilike(fragment("coalesce(?, '')", u.username), ^pattern) or
          ilike(
            fragment("concat_ws(' ', ?, ?)", u.first_name, u.last_name),
            ^pattern
          ),
      order_by: [
        desc:
          ilike(u.email, ^prefix) or
            ilike(fragment("concat_ws(' ', ?, ?)", u.first_name, u.last_name), ^prefix),
        asc: u.email
      ],
      limit: @search_limit
    )
    |> RepoHelper.repo().all()
  end

  @doc """
  Attaches the person `person_uuid` to the organization: a link of `type_key`
  (nil is the manager, with all roles) to a managed organization, else the
  older tie.
  """
  @spec attach(term(), User.t(), String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def attach(actor, %User{} = org, person_uuid, type_key \\ nil) do
    with {:ok, person} <- fetch_person(person_uuid) do
      PersonOrganizations.attach(actor, person, org.uuid, type_key)
    end
  end

  @doc """
  Detaches the person from the organization, whichever tie it is.
  `anyway: true` lets an Owner or Admin take the last manager away.
  """
  @spec detach(term(), User.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def detach(actor, %User{} = org, person_uuid, opts \\ []) do
    with {:ok, person} <- fetch_person(person_uuid) do
      PersonOrganizations.detach(actor, person, org.uuid, opts)
    end
  end

  @doc """
  Invites `email` to act for a managed organization as `type_key` (nil is the
  manager, with all roles). The answer is the same whether or not the address
  has an account, as on the People tab.
  """
  @spec invite(term(), User.t(), String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def invite(actor, %User{managed_by_members: true} = org, email, type_key \\ nil)
      when is_binary(email) do
    opts = if type_key in [nil, ""], do: [], else: [type: type_key]

    case Invitations.create_invitation(org, String.trim(email), actor, [kind: :manager] ++ opts) do
      {:ok, invitation, _token} -> {:ok, invitation}
      {:error, _} = error -> error
    end
  end

  @doc "Whether `term` reads as an email address someone could be invited at."
  @spec email?(String.t()) :: boolean()
  def email?(term) when is_binary(term),
    do: String.match?(String.trim(term), ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)

  defp fetch_person(uuid) do
    case Auth.get_user(uuid) do
      %User{account_type: "person"} = person -> {:ok, person}
      _ -> {:error, :person_not_found}
    end
  end

  defp escape_like(term), do: String.replace(term, ["%", "_", "\\"], &("\\" <> &1))
end
