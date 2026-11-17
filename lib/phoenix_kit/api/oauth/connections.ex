defmodule PhoenixKit.API.OAuth.Connections do
  @moduledoc """
  The connected applications a person sees on "My API keys" and an Owner sees on Settings -> API:
  the live grants (`PhoenixKit.API.OAuth.Grant`: activated, not revoked, not expired), with the
  client and the person each belongs to, and the one way a person ends one from a page.

  ## Who sees and ends what

    * View `:own` - the grants of the person behind `scope`, while they hold `api_personal_keys`
      or `api` (`PhoenixKit.API.Keys.holds_personal_right?/1`); nothing otherwise. A person who
      lost the right sees none and ends none, as with personal keys.
    * View `:all` - everyone's grants, for an Owner who holds `api` alone. Anyone else gets `[]`
      from `list/2` and `{:error, :forbidden}` from `revoke/3`.

  The caller hands in the scope it read **for this request** (`PhoenixKit.API.Access.fresh_scope/2`):
  nothing here caches a right. `revoke/3` finds the grant inside the view, so a uuid taken from
  a forged event that is not one of the person's grants is `{:error, :not_found}`, never an
  action on someone else's row. Ending goes through `PhoenixKit.API.OAuth.Grants.revoke/2` (the
  key, the grant and every token, in the lock order of that module) with the person as the actor
  of the `oauth.grant_revoked` entry.

  Each row carries `name`: the client's name **as it was when the person consented** (what the
  hidden key of the grant was named after), `nil` for a key whose name is not in that form, in
  which case the page falls back to the client's current name.

  ## Status

  `:active` while the grant's owner may use it. The effective rights of a request are the grant's
  scopes narrowed to what the owner holds right now, so a grant is **not removed** when the owner
  loses `api_personal_keys` (or `api`, or is blocked): it stays listed, marked `:no_permission` or
  `:owner_inactive`, and works again if the right comes back. `:wrong_resource` is a grant made for
  another address of the site (the `site_url` changed): no token of it is accepted.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  # A page lists the newest of them; it says so when it got this many (`limit/0`).
  @limit 200

  # How `PhoenixKit.API.Keys.create_oauth_key/3` names a grant's hidden key.
  @name_prefix "OAuth: "

  @type view :: :own | :all
  @type status :: :active | :no_permission | :owner_inactive | :wrong_resource
  @type row :: %{
          grant: Grant.t(),
          client: Client.t(),
          name: String.t() | nil,
          owner: User.t(),
          status: status()
        }

  @doc "How many connections `list/2` returns at most; a page shows a notice when it got this many."
  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc "The live connections `scope` may see in `view`, newest first (at most `limit/0`)."
  @spec list(Scope.t() | nil, view()) :: [row()]
  def list(scope, view) when view in [:own, :all] do
    case visible(scope, view) do
      nil -> []
      query -> query |> from(order_by: [desc: :inserted_at, desc: :uuid], limit: @limit) |> rows()
    end
  end

  @doc """
  Ends the connection `grant_uuid` as the person behind `scope`, found in `view`.

  Returns `{:ok, grant}`, `{:error, :forbidden}` (the all-view of someone who is not an Owner) or
  `{:error, :not_found}` (not one of the grants the view shows: unknown, malformed, someone
  else's, already ended, or the person lost the right).
  """
  @spec revoke(Scope.t() | nil, term(), view()) ::
          {:ok, Grant.t()} | {:error, :forbidden | :not_found | term()}
  def revoke(scope, grant_uuid, view) when view in [:own, :all] do
    with :ok <- check_view(scope, view),
         true <- is_binary(grant_uuid) and UUIDUtils.valid?(grant_uuid),
         %Grant{} = grant <- find(scope, grant_uuid, view) do
      Grants.revoke(grant, actor_uuid: Scope.user_uuid(scope))
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _not_visible -> {:error, :not_found}
    end
  end

  defp check_view(scope, :all), do: if(owner?(scope), do: :ok, else: {:error, :forbidden})
  defp check_view(_scope, :own), do: :ok

  defp find(scope, grant_uuid, view) do
    case visible(scope, view) do
      nil -> nil
      query -> repo().one(from([grant: g] in query, where: g.uuid == ^grant_uuid, select: g))
    end
  end

  # The base query of a view, or nil when the person may see none of it.
  defp visible(%Scope{user: %User{uuid: user_uuid}} = scope, :own) do
    if Keys.holds_personal_right?(scope),
      do: live_query(from([grant: g] in base(), where: g.user_uuid == ^user_uuid))
  end

  defp visible(scope, :all), do: if(owner?(scope), do: live_query(base()))
  defp visible(_scope, _view), do: nil

  defp owner?(scope), do: Scope.owner?(scope) and Scope.can?(scope, "api")

  defp base, do: from(g in Grant, as: :grant)

  defp live_query(query) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    from([grant: g] in query,
      where: not is_nil(g.activated_at) and is_nil(g.revoked_at) and g.expires_at > ^now
    )
  end

  defp rows(query) do
    records =
      repo().all(
        from([grant: g] in query,
          join: c in Client,
          on: c.uuid == g.client_uuid,
          join: k in Key,
          on: k.uuid == g.key_uuid,
          join: u in User,
          on: u.uuid == g.user_uuid,
          select: {g, c, k, u}
        )
      )

    states = owner_states(records)

    Enum.map(records, fn {grant, client, key, owner} ->
      %{
        grant: grant,
        client: client,
        name: pinned_name(key),
        owner: owner,
        status: status(grant, states[owner.uuid])
      }
    end)
  end

  # The name the person saw on the consent screen: the hidden key of the grant was named after it
  # (`"OAuth: <name>"`) when the consent was given. The client's row may carry another name now
  # (a metadata document is fetched again and can change), and a list that shows the new one would
  # not show what was agreed to.
  defp pinned_name(%Key{name: @name_prefix <> name}) when name != "", do: name
  defp pinned_name(_key), do: nil

  # The owner's state is read once per person (it costs a permission check), from one of their
  # hidden keys: `Keys.active_owner/1` is the check a request makes.
  defp owner_states(records) do
    records
    |> Enum.uniq_by(fn {_grant, _client, _key, owner} -> owner.uuid end)
    |> Map.new(fn {_grant, _client, key, owner} ->
      state =
        case Keys.active_owner(key) do
          {:ok, _owner} -> :ok
          {:error, :personal_keys_not_allowed} -> :no_permission
          {:error, _inactive} -> :owner_inactive
        end

      {owner.uuid, state}
    end)
  end

  defp status(grant, owner_state) do
    cond do
      not Resource.matches?(grant.resource) -> :wrong_resource
      owner_state == :no_permission -> :no_permission
      owner_state == :owner_inactive -> :owner_inactive
      true -> :active
    end
  end

  defp repo, do: RepoHelper.repo()
end
