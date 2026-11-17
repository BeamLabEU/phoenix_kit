defmodule PhoenixKit.API.OAuth.ConnectionsTest do
  @moduledoc """
  What a person sees of their connected applications and who may end which connection: a holder
  of `api_personal_keys` or `api` lists and ends their own, an Owner lists and ends everyone's,
  anyone else sees nothing and ends nothing. The rights are read from the scope that is handed in
  (a page hands in a freshly read one), and a person who lost the right sees nothing at once.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Connections
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RolePermission

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, role, scope} = oauth_holder(["media"])
    %{user: user, role: role, scope: scope}
  end

  defp drop_right!(role, right) do
    import Ecto.Query, only: [from: 2]

    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == ^right)
      )

    :ok
  end

  describe "list/2 for one person" do
    test "lists the live connections of the person, newest first, with the client", ctx do
      first = seed_grant!(ctx.scope)
      second = seed_grant!(ctx.scope)

      assert [one, two] = Connections.list(ctx.scope, :own)
      assert one.grant.uuid == second.grant.uuid
      assert two.grant.uuid == first.grant.uuid
      assert one.client.uuid == second.client.uuid
      assert one.status == :active
    end

    test "carries the name of the client as the person saw it, not the one it has now", ctx do
      client = client!(%{client_name: "Claude"})
      seed_grant!(ctx.scope, client: client)

      # The client's document says something else a day later.
      client |> Ecto.Changeset.change(client_name: "Somebody else") |> Repo.update!()

      assert [%{name: "Claude", client: %{client_name: "Somebody else"}}] =
               Connections.list(ctx.scope, :own)
    end

    test "leaves out the connections of other people", ctx do
      seed_grant!(ctx.scope)
      {_other, _role, other_scope} = oauth_holder(["media"])
      theirs = seed_grant!(other_scope)

      assert [%{grant: %Grant{uuid: uuid}}] = Connections.list(other_scope, :own)
      assert uuid == theirs.grant.uuid
      assert length(Connections.list(ctx.scope, :own)) == 1
    end

    test "leaves out a revoked grant, an expired one and one that was never activated", ctx do
      live = seed_grant!(ctx.scope)
      revoked = seed_grant!(ctx.scope)
      expired = seed_grant!(ctx.scope)
      open = seed_grant!(ctx.scope)

      {:ok, _} = Grants.revoke(revoked.grant)

      Repo.update_all(
        from_grant(expired.grant),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      Repo.update_all(from_grant(open.grant), set: [activated_at: nil])

      assert [%{grant: %Grant{uuid: uuid}}] = Connections.list(ctx.scope, :own)
      assert uuid == live.grant.uuid
    end

    test "a person who lost the right sees nothing", ctx do
      seed_grant!(ctx.scope)
      drop_right!(ctx.role, "api_personal_keys")

      fresh = scope_of(Repo.get!(PhoenixKit.Users.Auth.User, ctx.user.uuid))
      assert Connections.list(fresh, :own) == []
    end

    test "nobody and a scope without a user get an empty list" do
      assert Connections.list(nil, :own) == []
      assert Connections.list(nil, :all) == []
    end
  end

  describe "status" do
    test "a grant whose owner lost the right is marked, not hidden from an Owner", ctx do
      seed_grant!(ctx.scope)
      drop_right!(ctx.role, "api_personal_keys")

      assert [%{status: :no_permission}] = Connections.list(owner_scope(), :all)
    end

    test "a grant whose owner is blocked is marked inactive", ctx do
      seed_grant!(ctx.scope)
      {:ok, _} = Auth.update_user_status(ctx.user, %{is_active: false})

      assert [%{status: :owner_inactive}] = Connections.list(owner_scope(), :all)
    end
  end

  describe "a grant made for another address of the site" do
    test "is listed as wrong_resource, whatever its owner may do", ctx do
      seed_grant!(ctx.scope, resource: "https://elsewhere.example/mcp/admin")

      assert [%{status: :wrong_resource}] = Connections.list(ctx.scope, :own)
    end
  end

  describe "list/2 for an Owner" do
    test "lists everyone's connections with the person's e-mail", ctx do
      mine = seed_grant!(ctx.scope)
      {other, _role, other_scope} = oauth_holder(["media"])
      theirs = seed_grant!(other_scope)

      rows = Connections.list(owner_scope(), :all)
      uuids = Enum.map(rows, & &1.grant.uuid)
      assert mine.grant.uuid in uuids and theirs.grant.uuid in uuids

      assert Enum.find(rows, &(&1.grant.uuid == theirs.grant.uuid)).owner.email == other.email
    end

    test "the all-view is the Owner's alone", ctx do
      seed_grant!(ctx.scope)
      assert Connections.list(ctx.scope, :all) == []

      {admin, _role} = user_with(["media"])
      assert Connections.list(scope_of(admin), :all) == []
    end
  end

  describe "revoke/3" do
    test "a person ends their own connection: the grant, its tokens and its key", ctx do
      seeded = seed_grant!(ctx.scope)

      assert {:ok, %Grant{revoked_at: %DateTime{}}} =
               Connections.revoke(ctx.scope, seeded.grant.uuid, :own)

      assert %Key{revoked_at: %DateTime{}} = Repo.get!(Key, seeded.key.uuid)
      assert {:error, _} = Tokens.verify(seeded.access, "203.0.113.9")
      assert Connections.list(ctx.scope, :own) == []
    end

    test "writes who ended it into the activity feed", ctx do
      seeded = seed_grant!(ctx.scope)
      {:ok, _} = Connections.revoke(ctx.scope, seeded.grant.uuid, :own)

      entry = activity("oauth.grant_revoked", ctx.user)
      assert entry.resource_uuid == seeded.grant.uuid
      assert entry.metadata["reason"] == "grant_revoked"
    end

    test "nobody ends another person's connection through the own view", ctx do
      {_other, _role, other_scope} = oauth_holder(["media"])
      theirs = seed_grant!(other_scope)

      assert {:error, :not_found} = Connections.revoke(ctx.scope, theirs.grant.uuid, :own)
      assert {:error, :forbidden} = Connections.revoke(ctx.scope, theirs.grant.uuid, :all)
      assert Repo.get!(Grant, theirs.grant.uuid).revoked_at == nil
    end

    test "an Owner ends anyone's connection from the all-view, and only from it", ctx do
      seeded = seed_grant!(ctx.scope)
      owner = owner_scope()

      assert {:error, :not_found} = Connections.revoke(owner, seeded.grant.uuid, :own)

      assert {:ok, %Grant{revoked_at: %DateTime{}}} =
               Connections.revoke(owner, seeded.grant.uuid, :all)
    end

    test "a person who lost the right ends nothing", ctx do
      seeded = seed_grant!(ctx.scope)
      drop_right!(ctx.role, "api_personal_keys")
      fresh = scope_of(Repo.get!(PhoenixKit.Users.Auth.User, ctx.user.uuid))

      assert {:error, :not_found} = Connections.revoke(fresh, seeded.grant.uuid, :own)
      assert Repo.get!(Grant, seeded.grant.uuid).revoked_at == nil
    end

    test "a malformed or unknown uuid is not found", ctx do
      assert {:error, :not_found} = Connections.revoke(ctx.scope, "nope", :own)
      assert {:error, :not_found} = Connections.revoke(ctx.scope, Ecto.UUID.generate(), :own)
      assert {:error, :not_found} = Connections.revoke(ctx.scope, nil, :own)
    end

    test "ending an ended connection is not found, not a second entry", ctx do
      seeded = seed_grant!(ctx.scope)
      {:ok, _} = Connections.revoke(ctx.scope, seeded.grant.uuid, :own)

      assert {:error, :not_found} = Connections.revoke(ctx.scope, seeded.grant.uuid, :own)
    end
  end

  defp owner_scope, do: scope_of(owner_user())

  defp from_grant(%Grant{uuid: uuid}) do
    import Ecto.Query, only: [from: 2]
    from(g in Grant, where: g.uuid == ^uuid)
  end

  defp activity(action, user) do
    import Ecto.Query, only: [from: 2]

    Repo.one!(
      from(e in PhoenixKit.Activity.Entry,
        where: e.action == ^action and e.actor_uuid == ^user.uuid
      )
    )
  end
end
