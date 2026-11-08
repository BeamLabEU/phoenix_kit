defmodule PhoenixKit.Users.PersonOrganizations do
  @moduledoc """
  A person's companies, from the person's side: list, find, attach, detach and
  create-and-attach. The admin's user page uses it for its quick Organizations
  control (`PhoenixKitWeb.Live.Components.PersonOrganizations`).

  It adds no rules of its own. A person reaches a company two ways, and each
  goes through the function that owns it:

    * a **link** to a managed organization (`OrganizationManagers.add/4`,
      `remove/4`), typed (manager, staff…), the tie that may act for it. Those
      functions check the actor (an Owner or Admin) and keep the last manager;
    * the older single tie, `users.organization_uuid`, to an organization with
      a login of its own (`Auth.set_organization/2`,
      `Auth.remove_from_organization/1`). A link cannot point at such a company
      (`:organization_not_active_managed`), so attaching one sets this tie,
      replacing any other.

  A new company is a managed organization made from a name alone, with the
  person as its first manager (`ManagedOrganizations.create/3`).
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.RelationshipTypes

  @search_limit 8

  @type entry :: %{
          organization: User.t(),
          kind: :link | :member,
          type: PhoenixKit.Users.RelationshipType.t() | nil
        }

  @doc """
  The person's companies by name: each link (`kind: :link`, with its `type`),
  then the older tie (`kind: :member`) unless the same company is linked too.
  """
  @spec list(User.t()) :: [entry()]
  def list(%User{account_type: "person"} = person) do
    links =
      for link <- OrganizationManagers.organizations_of(person.uuid) do
        %{organization: link.organization, kind: :link, type: link.type}
      end

    linked = MapSet.new(links, & &1.organization.uuid)

    member =
      with uuid when is_binary(uuid) <- person.organization_uuid,
           false <- MapSet.member?(linked, uuid),
           %User{account_type: "organization"} = org <- Auth.get_user(uuid) do
        [%{organization: org, kind: :member, type: nil}]
      else
        _ -> []
      end

    Enum.sort_by(links ++ member, &String.downcase(name(&1.organization)))
  end

  def list(_user), do: []

  @doc """
  For a list of accounts (a page of the Users table), each person's companies
  by name, as `%{person_uuid => [organization]}`, in two queries whatever the
  page size: the links, then the older tie (read from a preloaded
  `:organization` when there is one). A company reached both ways is listed
  once; an account with none is left out of the map.
  """
  @spec organizations_by_person([User.t()]) :: %{String.t() => [User.t()]}
  def organizations_by_person(users) when is_list(users) do
    people = Enum.filter(users, &match?(%User{account_type: "person"}, &1))
    uuids = Enum.map(people, & &1.uuid)

    linked =
      from(m in OrganizationManager,
        join: org in assoc(m, :organization),
        where: m.user_uuid in ^uuids and org.managed_by_members and org.is_active,
        select: {m.user_uuid, org}
      )
      |> RepoHelper.repo().all()

    tied = Enum.flat_map(people, &older_tie/1)

    (linked ++ tied)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {uuid, orgs} ->
      {uuid, orgs |> Enum.uniq_by(& &1.uuid) |> Enum.sort_by(&String.downcase(name(&1)))}
    end)
  end

  # As `list/1` reads it: any organization the column points at.
  defp older_tie(%User{organization_uuid: nil}), do: []

  defp older_tie(%User{organization: %User{account_type: "organization"} = org} = person),
    do: [{person.uuid, org}]

  defp older_tie(%User{organization: %Ecto.Association.NotLoaded{}} = person) do
    case Auth.get_user(person.organization_uuid) do
      %User{account_type: "organization"} = org -> [{person.uuid, org}]
      _ -> []
    end
  end

  defp older_tie(_person), do: []

  @doc """
  Active organizations whose name contains `term`, those starting with it
  first, leaving out the ones in `exclude_uuids`. An empty term lists the
  first few by name, so a short list shows at once.
  """
  @spec search(String.t(), [String.t()]) :: [User.t()]
  def search(term, exclude_uuids \\ []) when is_binary(term) do
    term = String.trim(term)
    pattern = "%" <> escape_like(term) <> "%"
    prefix = escape_like(term) <> "%"

    from(u in User,
      where: u.account_type == "organization" and u.is_active and not u.api_only,
      where: u.uuid not in ^exclude_uuids,
      where: ilike(fragment("coalesce(?, '')", u.organization_name), ^pattern),
      order_by: [
        desc: ilike(fragment("coalesce(?, '')", u.organization_name), ^prefix),
        asc: fragment("lower(coalesce(?, ''))", u.organization_name)
      ],
      limit: @search_limit
    )
    |> RepoHelper.repo().all()
  end

  @doc "Whether an active organization is already called `name` (any case)."
  @spec name_taken?(String.t()) :: boolean()
  def name_taken?(name) when is_binary(name) do
    name = String.trim(name)

    name != "" and
      RepoHelper.repo().exists?(
        from(u in User,
          where: u.account_type == "organization" and u.is_active and not u.api_only,
          where: fragment("lower(?)", u.organization_name) == ^String.downcase(name)
        )
      )
  end

  @doc """
  The link types a person can have with a company: active, acting, person to
  organization. The built-in manager comes first.
  """
  @spec link_types() :: [PhoenixKit.Users.RelationshipType.t()]
  def link_types do
    RelationshipTypes.list_types(status: :active)
    |> Enum.filter(&(&1.can_act and &1.from_kind == "person" and &1.to_kind == "organization"))
  end

  @doc """
  Attaches the person to `organization_uuid`: a link of `type_key` (nil is the
  manager, with all roles) to a managed organization, else the older tie.
  """
  @spec attach(term(), User.t(), String.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def attach(actor, %User{} = person, organization_uuid, type_key \\ nil) do
    case Auth.get_user(organization_uuid) do
      %User{account_type: "organization", managed_by_members: true} = org ->
        opts = if type_key in [nil, ""], do: [], else: [type: type_key]
        OrganizationManagers.add(actor, org.uuid, person.uuid, opts)

      %User{account_type: "organization"} = org ->
        Auth.set_organization(person, org.uuid)

      _ ->
        {:error, :organization_not_found}
    end
  end

  @doc """
  Detaches the person from `organization_uuid`, whichever tie it is.
  `anyway: true` lets an Owner or Admin take a company's last manager away.
  """
  @spec detach(term(), User.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def detach(actor, %User{} = person, organization_uuid, opts \\ []) do
    case Enum.find(list(person), &(&1.organization.uuid == organization_uuid)) do
      %{kind: :link} ->
        actor
        |> OrganizationManagers.remove(organization_uuid, person.uuid,
          allow_managerless: Keyword.get(opts, :anyway, false)
        )
        |> ok()

      %{kind: :member} ->
        person |> Auth.remove_from_organization() |> ok()

      nil ->
        :ok
    end
  end

  @doc "Creates a managed organization called `name` with the person as its first manager."
  @spec create_and_attach(term(), User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def create_and_attach(actor, %User{} = person, name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" -> {:error, :name_required}
      name_taken?(name) -> {:error, :name_taken}
      true -> ManagedOrganizations.create(actor, %{"organization_name" => name}, person.uuid)
    end
  end

  @doc "How a company is called on screen."
  @spec name(User.t()) :: String.t()
  def name(%User{organization_name: name}) when is_binary(name) and name != "", do: name
  def name(%User{} = org), do: User.delivery_email(org)

  defp ok({:ok, _}), do: :ok
  defp ok(:ok), do: :ok
  defp ok({:error, _} = error), do: error

  defp escape_like(term), do: String.replace(term, ["%", "_", "\\"], &("\\" <> &1))
end
