defmodule PhoenixKit.API.OAuth.ExchangeConcurrencyTest do
  @moduledoc """
  The one-shot rules of the token endpoint under real concurrency: separate database sessions,
  real commits, no sandbox. A code is redeemed by one caller; a refresh token is rotated by one
  caller, and a burst of presentations of one used token is never more than one new pair
  (the retry window) before the family is revoked.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import PhoenixKit.API.OAuthTestSupport

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Codes
  alias PhoenixKit.API.OAuth.Exchange
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.Test.Repo

  @moduletag :integration
  @callers 10

  setup do
    Sandbox.mode(Repo, :auto)
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()
    {user, role, scope} = oauth_holder(["media"])
    {verifier, challenge} = pkce()
    client = client!()
    redirect_uri = hd(client.redirect_uris)

    {:ok, grant, key} =
      Grants.create(
        scope,
        client,
        %{
          scopes: [KeyTestSupport.read_scope()],
          expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
        },
        impersonated: false
      )

    {:ok, code, _row} =
      Codes.issue(grant, %{redirect_uri: redirect_uri, code_challenge: challenge})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(t in Token, where: t.grant_uuid == ^grant.uuid))
      Repo.delete_all(from(c in PhoenixKit.API.OAuth.Code, where: c.grant_uuid == ^grant.uuid))
      Repo.delete_all(from(g in Grant, where: g.uuid == ^grant.uuid))
      Repo.delete_all(from(k in PhoenixKit.API.Keys.Key, where: k.uuid == ^key.uuid))
      Repo.delete_all(from(c in Client, where: c.uuid == ^client.uuid))
      Repo.delete_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^user.uuid))
      Repo.delete_all(from(r in PhoenixKit.Users.Role, where: r.uuid == ^role.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{
      grant: grant,
      client: client,
      params: %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier,
        "redirect_uri" => redirect_uri,
        "client_id" => client.client_id
      }
    }
  end

  defp concurrently(count, fun) do
    1..count
    |> Task.async_stream(fun, max_concurrency: count, timeout: 60_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "simultaneous exchanges of one code give at most one pair, and a replay revokes the grant",
       ctx do
    results = concurrently(@callers, fn _ -> Exchange.token(ctx.params) end)

    # A loser that finds the code already used revokes the grant (a replayed code means a stolen
    # one), which can happen before the winner has activated it: then nobody gets a pair.
    # Never more than one.
    assert Enum.count(results, &match?({:ok, %{"access_token" => _}}, &1)) <= 1, inspect(results)
    assert Enum.count(results, &match?({:error, "invalid_grant", _}, &1)) >= @callers - 1

    # A replay of the code (whichever order the callers ran in) ends the grant.
    assert {:error, "invalid_grant", _} = Exchange.token(ctx.params)
    assert %Grant{revoked_at: %DateTime{}} = Repo.get!(Grant, ctx.grant.uuid)
  end

  test "simultaneous refreshes of one token never leave two live successors", ctx do
    {:ok, %{"refresh_token" => refresh}} = Exchange.token(ctx.params)

    request = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh,
      "client_id" => ctx.client.client_id
    }

    results = concurrently(@callers, fn _ -> Exchange.token(request) end)
    wins = Enum.filter(results, &match?({:ok, %{"refresh_token" => _}}, &1))

    # The first caller rotates; the others are retries inside the window, each superseding the
    # previous successor. Whatever the interleaving, at most one refresh token of the family
    # is left unused and live.
    assert wins != []

    live_refresh =
      Repo.aggregate(
        from(t in Token,
          where:
            t.grant_uuid == ^ctx.grant.uuid and t.kind == "refresh" and is_nil(t.used_at) and
              is_nil(t.revoked_at)
        ),
        :count
      )

    assert live_refresh == 1
  end
end
