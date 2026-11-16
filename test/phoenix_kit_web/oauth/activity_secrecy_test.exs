defmodule PhoenixKitWeb.OAuth.ActivitySecrecyTest do
  @moduledoc """
  The six `oauth.*` Activity entries (grant created, grant revoked, refresh retry, refresh reuse,
  client registered, client removed) hold no secret: not the authorization code, the PKCE verifier, an access or a
  refresh token, nor the key behind the grant or its hash. The feed is read by everyone who may
  read Activity, and entries are kept past the end of a connection.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.OAuthFlowSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, enable_oauth!: 0]
  import PhoenixKit.Test.ApiHarness, only: [put_setting: 2, setup_api: 0]

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.Test.Repo

  @read "testkit.items:read"
  @actions ~w(oauth.grant_created oauth.grant_revoked oauth.refresh_retry oauth.refresh_reuse
              oauth.client_registered oauth.client_removed)

  setup do
    setup_api()
    enable_oauth!()
    put_setting("api_oauth_dcr_enabled", "true")
    Limits.reset(:register_global, nil)
    {user, _role} = holder(["dashboard", "settings"])
    %{user: user, client: client!()}
  end

  defp entries(user) do
    Repo.all(
      from(e in Entry,
        where: e.action in ^@actions and (e.actor_uuid == ^user.uuid or is_nil(e.actor_uuid)),
        order_by: e.inserted_at
      )
    )
  end

  test "every kind of entry is written and none of them holds an issued secret", ctx do
    %{user: user, client: client} = ctx
    flow = code_for(user, client, [@read])

    %{"access_token" => a1, "refresh_token" => r1} = flow |> exchange_code() |> body()

    # A retry inside the window, then the replay of a refresh token that was handed on.
    %{"access_token" => a2, "refresh_token" => r2} = client |> refresh(r1) |> body()
    %{"access_token" => a3, "refresh_token" => r3} = client |> refresh(r1) |> body()
    assert refresh(client, r2).status == 400

    # A second connection, ended by hand, a client that registered itself, and a client removed.
    flow2 = code_for(user, client, [@read])
    %{"access_token" => a4, "refresh_token" => r4} = flow2 |> exchange_code() |> body()

    grant =
      Repo.one!(
        from(g in Grant, where: is_nil(g.revoked_at), order_by: [desc: g.inserted_at], limit: 1)
      )

    {:ok, _} = Grants.revoke(grant, actor_uuid: user.uuid)

    assert register(%{
             "redirect_uris" => ["https://app.example/oauth/callback"],
             "client_name" => "Secrecy Agent"
           }).status == 201

    # Removing a client ends the connections it still has and is an entry of its own.
    {:ok, _} = Clients.delete(client, actor_uuid: user.uuid)

    rows = entries(user)
    seen = rows |> Enum.map(& &1.action) |> Enum.uniq() |> Enum.sort()
    assert seen == Enum.sort(@actions)

    secrets = [
      flow.code,
      flow.verifier,
      flow2.code,
      flow2.verifier,
      a1,
      r1,
      a2,
      r2,
      a3,
      r3,
      a4,
      r4
    ]

    dump =
      rows
      |> Enum.map_join(
        "\n",
        &inspect(Map.take(&1, [:metadata, :resource_uuid, :resource_type, :action, :mode]))
      )

    for secret <- secrets do
      assert byte_size(secret) > 8
      refute dump =~ secret
    end

    refute dump =~ "pkoa_"
    refute dump =~ "pkor_"
  end
end
