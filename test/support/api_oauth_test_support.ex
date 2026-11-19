defmodule PhoenixKit.API.OAuthTestSupport do
  @moduledoc """
  Fixtures for the tests of the OAuth side of the machine API: a person who holds
  `api_personal_keys` (and **not** `api`, the real case of an Admin who may connect an
  application), a client, and a seeded grant with its tokens, built through the real
  `PhoenixKit.API.OAuth.Grants` and `PhoenixKit.API.OAuth.Tokens`. Nothing here goes through an
  authorization flow: the tests of the resource side start from a grant that exists.

  Import `PhoenixKit.API.KeyTestSupport` as well: the fake module's scopes are the ones a
  seeded grant carries (`read_scope/0` by default).
  """

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth.User

  @doc """
  A confirmed user holding `permissions` and `api_personal_keys`, but not `api`.
  Returns `{user, role, scope}`.
  """
  @spec oauth_holder([String.t()]) ::
          {User.t(), PhoenixKit.Users.Role.t(), PhoenixKit.Users.Auth.Scope.t()}
  def oauth_holder(permissions \\ ["media"]) do
    {user, role} = KeyTestSupport.user_without_api(Enum.uniq(["api_personal_keys" | permissions]))
    {user, role, KeyTestSupport.scope_of(user)}
  end

  @doc "Switches the admin API and OAuth on (`api_admin_enabled`, `api_oauth_enabled`)."
  @spec enable_oauth!() :: :ok
  def enable_oauth! do
    for key <- ~w(api_admin_enabled api_oauth_enabled) do
      KeyTestSupport.write_setting(fn -> Settings.update_boolean_setting(key, true) end)
    end

    :ok
  end

  @doc "A pre-registered client with a unique `client_id`."
  @spec client!(map()) :: PhoenixKit.API.OAuth.Client.t()
  def client!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, client} =
      Clients.register_preregistered(
        Map.merge(
          %{
            client_id: "https://client.example/#{n}",
            client_name: "Test client #{n}",
            redirect_uris: ["https://client.example/callback"]
          },
          attrs
        )
      )

    client
  end

  @doc """
  A grant of a new client for the person behind `scope`, with an access token and a refresh
  token. `opts`: `:scopes` (default the fake module's read scope), `:expires_at` (default ten
  days), `:client`, `:resource`, `:access_expires_at`.

  Returns `%{grant, key, client, access, refresh, access_row, refresh_row}`.
  """
  @spec seed_grant!(PhoenixKit.Users.Auth.Scope.t(), keyword()) :: map()
  def seed_grant!(scope, opts \\ []) do
    client = Keyword.get_lazy(opts, :client, &client!/0)

    attrs =
      %{
        scopes: Keyword.get(opts, :scopes, [KeyTestSupport.read_scope()]),
        expires_at:
          Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 10 * 86_400, :second))
      }
      |> maybe_put(:resource, Keyword.get(opts, :resource))

    {:ok, grant, key} = Grants.create(scope, client, attrs, impersonated: false)

    {:ok, grant} =
      grant
      |> Ecto.Changeset.change(activated_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update()

    access_opts =
      case Keyword.get(opts, :access_expires_at) do
        nil -> []
        at -> [expires_at: at]
      end

    {:ok, access, access_row} = Tokens.issue(grant, :access, access_opts)
    {:ok, refresh, refresh_row} = Tokens.issue(grant, :refresh, family: access_row.family)

    %{
      grant: grant,
      key: key,
      client: client,
      access: access,
      refresh: refresh,
      access_row: access_row,
      refresh_row: refresh_row
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
