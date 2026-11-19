defmodule PhoenixKit.API.OAuth.GrantsTest do
  @moduledoc """
  `PhoenixKit.API.OAuth.Grants.create/4`: the grant and its hidden key are made together or
  not at all, the key ends where the grant ends, and two consents of one person and one
  client are two grants.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Resource

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, _role, scope} = oauth_holder(["media"])
    %{user: user, scope: scope, client: client!()}
  end

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{scopes: [read_scope()], expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)},
      extra
    )
  end

  test "makes the grant and its key, pointing at each other, with one expiry", ctx do
    assert {:ok, %Grant{} = grant, %Key{} = key} =
             Grants.create(ctx.scope, ctx.client, attrs(%{created_ip: "203.0.113.5"}),
               impersonated: false
             )

    assert grant.user_uuid == ctx.user.uuid
    assert grant.client_uuid == ctx.client.uuid
    assert grant.key_uuid == key.uuid
    assert key.oauth_grant_uuid == grant.uuid
    assert grant.scopes == [read_scope()]
    assert grant.resource == Resource.resource()
    assert grant.created_ip == "203.0.113.5"
    assert grant.activated_at == nil and grant.revoked_at == nil
    assert key.expires_at == grant.expires_at
    assert key.name == "OAuth: " <> ctx.client.client_name
  end

  test "the key is named after the client name the caller passes, or the client's own", ctx do
    assert {:ok, _grant, key} =
             Grants.create(ctx.scope, ctx.client, attrs(%{client_name: "Seen at consent"}),
               impersonated: false
             )

    assert key.name == "OAuth: Seen at consent"

    assert {:ok, _grant, key} =
             Grants.create(ctx.scope, ctx.client, attrs(%{client_name: nil}), impersonated: false)

    assert key.name == "OAuth: " <> ctx.client.client_name
  end

  test "a client name the table cannot hold is a refusal, not a database error", ctx do
    for name <- ["a\0b", <<0xFF, 0xFE>>] do
      assert {:error, :invalid_client_name} =
               Grants.create(ctx.scope, ctx.client, attrs(%{client_name: name}),
                 impersonated: false
               )
    end

    assert Repo.aggregate(Grant, :count) == 0
  end

  test "a client deleted since it was read is :client_gone, not a constraint error, and leaves nothing",
       ctx do
    Repo.delete!(ctx.client)

    assert Grants.create(ctx.scope, ctx.client, attrs(), impersonated: false) ==
             {:error, :client_gone}

    assert Repo.all(Grant) == []
    assert Repo.all(from(k in Key, where: not is_nil(k.oauth_grant_uuid))) == []
  end

  test "a client name of combining marks makes a key, not a database error", ctx do
    # A name `Clients` keeps whole (80 graphemes, 160 code points) is 167 code points once
    # "OAuth: " leads it: past the 160 of the key's column.
    client = client!(%{client_name: String.duplicate("a\u0301", 80)})

    assert {:ok, %Grant{}, %Key{} = key} =
             Grants.create(ctx.scope, client, attrs(), impersonated: false)

    assert key.name |> String.to_charlist() |> length() <= 160
    assert Repo.get!(Key, key.uuid).name == key.name
  end

  test "an address longer than its column is cut, not a database error", ctx do
    long = String.duplicate("1", 80)

    assert {:ok, grant, _key} =
             Grants.create(ctx.scope, ctx.client, attrs(%{created_ip: long}), impersonated: false)

    assert grant.created_ip == String.duplicate("1", 45)
    assert Repo.get!(Grant, grant.uuid).created_ip == String.duplicate("1", 45)

    assert {:ok, no_ip, _key} =
             Grants.create(ctx.scope, ctx.client, attrs(%{created_ip: 5}), impersonated: false)

    assert no_ip.created_ip == nil
  end

  test "the grant is stored as made", ctx do
    {:ok, grant, _key} = Grants.create(ctx.scope, ctx.client, attrs(), impersonated: false)
    assert Grants.get(grant.uuid).key_uuid == grant.key_uuid
    assert Grants.get("nope") == nil
    assert Grants.get(nil) == nil
  end

  test "each consent is a new grant, none revokes another", ctx do
    {:ok, first, first_key} = Grants.create(ctx.scope, ctx.client, attrs(), impersonated: false)
    {:ok, second, second_key} = Grants.create(ctx.scope, ctx.client, attrs(), impersonated: false)

    assert first.uuid != second.uuid
    assert first_key.uuid != second_key.uuid
    refute Repo.get!(Grant, first.uuid).revoked_at
    refute Repo.get!(Key, first_key.uuid).revoked_at
  end

  test "a refusal leaves neither a grant nor a key", ctx do
    before_grants = Repo.aggregate(Grant, :count)
    before_keys = Repo.aggregate(Key, :count)

    assert {:error, :impersonated} =
             Grants.create(ctx.scope, ctx.client, attrs(), impersonated: true)

    assert {:error, :invalid_scopes} =
             Grants.create(ctx.scope, ctx.client, attrs(%{scopes: [write_scope()]}),
               impersonated: false
             )

    assert {:error, %Ecto.Changeset{}} =
             Grants.create(ctx.scope, ctx.client, attrs(%{expires_at: nil}), impersonated: false)

    assert {:error, :forbidden} = Grants.create(nil, ctx.client, attrs(), impersonated: false)

    assert Repo.aggregate(Grant, :count) == before_grants
    assert Repo.aggregate(Key, :count) == before_keys
  end

  test "removing the owner removes the grant with its key", ctx do
    {:ok, grant, key} = Grants.create(ctx.scope, ctx.client, attrs(), impersonated: false)
    Repo.delete!(Repo.get!(PhoenixKit.Users.Auth.User, ctx.user.uuid))

    assert Repo.get(Grant, grant.uuid) == nil
    assert Repo.get(Key, key.uuid) == nil
  end
end
