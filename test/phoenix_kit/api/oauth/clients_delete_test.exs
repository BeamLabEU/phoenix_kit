defmodule PhoenixKit.API.OAuth.ClientsDeleteTest do
  @moduledoc """
  `Clients.delete/1`: a client is never removed while a grant of it is alive. The database would
  take the grants and their tokens with the client (`ON DELETE CASCADE`) and leave their hidden
  keys behind, still valid; so every grant is ended first, through `Grants.revoke/2`, in the same
  transaction.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.API.OAuth.Tokens

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, _role, scope} = oauth_holder(["media"])
    %{user: user, scope: scope, client: client!()}
  end

  defp key_state(key), do: Repo.get!(Key, key.uuid)

  test "ends every grant of the client, kills its keys, then removes the client", ctx do
    first = seed_grant!(ctx.scope, client: ctx.client)
    second = seed_grant!(ctx.scope, client: ctx.client)

    assert {:ok, %Client{}} = Clients.delete(ctx.client, actor_uuid: ctx.user.uuid)

    assert Repo.get(Client, ctx.client.uuid) == nil
    assert Repo.all(from(g in Grant, where: g.client_uuid == ^ctx.client.uuid)) == []

    for seeded <- [first, second] do
      assert %Key{revoked_at: %DateTime{}} = key_state(seeded.key)
      assert Repo.all(from(t in Token, where: t.grant_uuid == ^seeded.grant.uuid)) == []
    end

    entries =
      Repo.all(
        from(e in Entry,
          where: e.action == "oauth.grant_revoked" and e.actor_uuid == ^ctx.user.uuid
        )
      )

    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.metadata["reason"] == "client_deleted"))
  end

  test "the access token of a deleted client's grant no longer opens anything", ctx do
    seeded = seed_grant!(ctx.scope, client: ctx.client)
    assert {:ok, _actor} = Tokens.verify(seeded.access, "203.0.113.9")

    assert {:ok, %Client{}} = Clients.delete(ctx.client.uuid)

    assert {:error, _reason} = Tokens.verify(seeded.access, "203.0.113.9")
  end

  test "another client's grants are left alone", ctx do
    other = seed_grant!(ctx.scope)
    seed_grant!(ctx.scope, client: ctx.client)

    assert {:ok, %Client{}} = Clients.delete(ctx.client)

    assert %Key{revoked_at: nil} = key_state(other.key)
    assert %Client{} = Repo.get(Client, other.client.uuid)

    assert [%Grant{revoked_at: nil}] =
             Repo.all(from(g in Grant, where: g.uuid == ^other.grant.uuid))
  end

  test "a client with no grant is simply removed, an unknown one is not found", ctx do
    assert {:ok, %Client{}} = Clients.delete(ctx.client)
    assert {:error, :not_found} = Clients.delete(ctx.client)
    assert {:error, :not_found} = Clients.delete("nope")
    assert {:error, :not_found} = Clients.delete(nil)
  end
end
