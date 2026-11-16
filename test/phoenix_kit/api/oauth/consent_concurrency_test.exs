defmodule PhoenixKit.API.OAuth.ConsentConcurrencyTest do
  @moduledoc """
  Consents answered at the same moment: separate database sessions, real commits, no sandbox.
  Two consents of one client make two live grants and revoke neither (the old grant is never
  touched by a new consent); one request answered twice makes one grant; and simultaneous
  consents at the ceiling never pass it together (`PhoenixKit.API.OAuth.Grants.create/4` counts
  and inserts under the person's advisory lock).
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import PhoenixKit.API.OAuthTestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Consent
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.Test.Repo

  @moduletag :integration
  @callers 6
  @ceiling 2

  setup do
    Sandbox.mode(Repo, :auto)
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()
    {user, role, scope} = oauth_holder(["media"])
    client = client!()
    KeyTestSupport.put_setting("api_oauth_grants_per_person", @ceiling)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      grants = Repo.all(from(g in Grant, where: g.user_uuid == ^user.uuid))
      grant_uuids = Enum.map(grants, & &1.uuid)

      Repo.delete_all(from(t in Token, where: t.grant_uuid in ^grant_uuids))
      Repo.delete_all(from(c in Code, where: c.grant_uuid in ^grant_uuids))
      Repo.delete_all(from(g in Grant, where: g.user_uuid == ^user.uuid))
      Repo.delete_all(from(r in Request, where: r.client_uuid == ^client.uuid))
      Repo.delete_all(from(k in Key, where: k.user_uuid == ^user.uuid))
      Repo.delete_all(from(c in Client, where: c.uuid == ^client.uuid))

      Repo.delete_all(
        from(e in PhoenixKit.Activity.Entry,
          where: e.actor_uuid == ^user.uuid or e.resource_uuid in ^grant_uuids
        )
      )

      Repo.delete_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^user.uuid))
      Repo.delete_all(from(r in PhoenixKit.Users.Role, where: r.uuid == ^role.uuid))
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = 'api_oauth_grants_per_person'")
      Sandbox.mode(Repo, :manual)
    end)

    %{user: user, scope: scope, client: client}
  end

  defp request!(client) do
    {:ok, _token, request} =
      Requests.create(client, %{
        redirect_uri: hd(client.redirect_uris),
        code_challenge: elem(pkce(), 1),
        resource: Resource.resource()
      })

    request
  end

  defp allow(scope, request, client) do
    Consent.allow(scope, request, client,
      scopes: [KeyTestSupport.read_scope()],
      days: 30,
      impersonated: false
    )
  end

  defp concurrently(funs) do
    funs
    |> Task.async_stream(& &1.(), max_concurrency: length(funs), timeout: 60_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "two consents of one client at once make two live grants and revoke neither", ctx do
    requests = for _ <- 1..2, do: request!(ctx.client)
    results = concurrently(Enum.map(requests, &fn -> allow(ctx.scope, &1, ctx.client) end))

    assert [{:ok, _, _}, {:ok, _, _}] = results
    assert Grants.count_live(ctx.user.uuid) == 2

    grants = Repo.all(from(g in Grant, where: g.user_uuid == ^ctx.user.uuid))
    assert length(grants) == 2
    assert Enum.all?(grants, &is_nil(&1.revoked_at))

    assert Repo.aggregate(
             from(k in Key, where: k.user_uuid == ^ctx.user.uuid and is_nil(k.revoked_at)),
             :count
           ) == 2
  end

  test "one request answered several times at once makes one grant and one code", ctx do
    request = request!(ctx.client)

    results =
      concurrently(for _ <- 1..@callers, do: fn -> allow(ctx.scope, request, ctx.client) end)

    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &match?({:error, :request_gone}, &1)) == @callers - 1

    assert Repo.aggregate(from(g in Grant, where: g.user_uuid == ^ctx.user.uuid), :count) == 1

    assert Repo.aggregate(
             from(c in Code,
               join: g in Grant,
               on: g.uuid == c.grant_uuid,
               where: g.user_uuid == ^ctx.user.uuid
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(r in Request,
               where: not is_nil(r.consumed_at) and r.client_uuid == ^ctx.client.uuid
             ),
             :count
           ) == 1
  end

  test "simultaneous consents at the ceiling never pass it together", ctx do
    assert {:ok, _, _} = allow(ctx.scope, request!(ctx.client), ctx.client)
    requests = for _ <- 1..@callers, do: request!(ctx.client)

    results = concurrently(Enum.map(requests, &fn -> allow(ctx.scope, &1, ctx.client) end))

    # One place was left: one consent gets it, the others are turned away at the ceiling, and a
    # refused answer leaves its request unused.
    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &match?({:error, :grant_limit}, &1)) == @callers - 1

    assert Grants.count_live(ctx.user.uuid) == @ceiling

    assert Repo.aggregate(from(g in Grant, where: g.user_uuid == ^ctx.user.uuid), :count) ==
             @ceiling

    unused =
      Repo.aggregate(
        from(r in Request, where: is_nil(r.consumed_at) and r.client_uuid == ^ctx.client.uuid),
        :count
      )

    assert unused == @callers - 1
  end
end
