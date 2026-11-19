defmodule PhoenixKit.API.OAuth.ClientsAdminTest do
  @moduledoc """
  What the Settings -> API page needs of `PhoenixKit.API.OAuth.Clients`: the list with the live
  grants each client has, and the activity entry of a client an administrator typed in.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Codes
  alias PhoenixKit.API.OAuth.Grants

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, _role, scope} = oauth_holder(["media"])
    %{user: user, scope: scope}
  end

  describe "list/0" do
    test "lists clients newest first with their live grants", ctx do
      old = client!()
      new = client!()

      # `inserted_at` has a resolution of a second: make the order a fact, not a race.
      Repo.update_all(from(c in PhoenixKit.API.OAuth.Client, where: c.uuid == ^old.uuid),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600) |> DateTime.truncate(:second)]
      )

      seed_grant!(ctx.scope, client: new)
      seed_grant!(ctx.scope, client: new)
      ended = seed_grant!(ctx.scope, client: new)
      {:ok, _} = Grants.revoke(ended.grant)

      rows = Clients.list()
      new_row = Enum.find(rows, &(&1.client.uuid == new.uuid))
      old_row = Enum.find(rows, &(&1.client.uuid == old.uuid))

      assert new_row.grants == 2
      assert old_row.grants == 0

      assert Enum.find_index(rows, &(&1.client.uuid == new.uuid)) <
               Enum.find_index(rows, &(&1.client.uuid == old.uuid))
    end

    test "a grant nobody activated is not counted", ctx do
      client = client!()
      open = seed_grant!(ctx.scope, client: client)

      Repo.update_all(from(g in PhoenixKit.API.OAuth.Grant, where: g.uuid == ^open.grant.uuid),
        set: [activated_at: nil]
      )

      assert Enum.find(Clients.list(), &(&1.client.uuid == client.uuid)).grants == 0
    end

    test "counts a consent just approved whose code is not yet exchanged, as the removal does",
         ctx do
      client = client!()
      attrs = %{scopes: [read_scope()], expires_at: DateTime.add(DateTime.utc_now(), 86_400)}
      {:ok, grant, _key} = Grants.create(ctx.scope, client, attrs, impersonated: false)
      {:ok, _code, row} = Codes.issue(grant, %{redirect_uri: "https://x/cb", code_challenge: "c"})

      assert Enum.find(Clients.list(), &(&1.client.uuid == client.uuid)).grants == 1

      # Once the code ran out nobody can finish the consent: it is no connection any more.
      Repo.update_all(from(c in PhoenixKit.API.OAuth.Code, where: c.uuid == ^row.uuid),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)]
      )

      assert Enum.find(Clients.list(), &(&1.client.uuid == client.uuid)).grants == 0
    end
  end

  describe "register_preregistered/2" do
    defp entries(client) do
      Repo.all(
        from(e in Entry,
          where: e.action == "oauth.client_registered" and e.resource_uuid == ^client.uuid
        )
      )
    end

    test "writes who typed the client in, with the redirect hosts and no path", ctx do
      attrs = %{
        client_id: "claude-#{System.unique_integer([:positive])}",
        client_name: "Claude",
        redirect_uris: [
          "https://claude.ai/api/mcp/auth_callback?secret=abc",
          "https://claude.ai/other"
        ]
      }

      assert {:ok, client} = Clients.register_preregistered(attrs, actor_uuid: ctx.user.uuid)

      assert [entry] = entries(client)
      assert entry.actor_uuid == ctx.user.uuid
      assert entry.permanent
      assert entry.metadata == %{"kind" => "preregistered", "redirect_hosts" => ["claude.ai"]}
      refute inspect(entry.metadata) =~ "secret"
    end

    test "writes nothing without an actor, and nothing for a refused client", ctx do
      {:ok, client} =
        Clients.register_preregistered(%{
          client_id: "plain-#{System.unique_integer([:positive])}"
        })

      assert entries(client) == []

      before = Repo.aggregate(Entry, :count)

      assert {:error, %Ecto.Changeset{}} =
               Clients.register_preregistered(%{client_id: "", redirect_uris: []},
                 actor_uuid: ctx.user.uuid
               )

      assert Repo.aggregate(Entry, :count) == before
    end
  end

  describe "delete/2" do
    defp removed_entries(client) do
      Repo.all(
        from(e in Entry,
          where: e.action == "oauth.client_removed" and e.resource_uuid == ^client.uuid
        )
      )
    end

    test "writes who removed the client and how many connections ended, even with none", ctx do
      idle = client!()
      busy = client!()
      seed_grant!(ctx.scope, client: busy)
      seed_grant!(ctx.scope, client: busy)

      assert {:ok, _} = Clients.delete(idle.uuid, actor_uuid: ctx.user.uuid)
      assert {:ok, _} = Clients.delete(busy.uuid, actor_uuid: ctx.user.uuid)

      assert [idle_entry] = removed_entries(idle)
      assert idle_entry.actor_uuid == ctx.user.uuid
      assert idle_entry.permanent
      assert idle_entry.metadata == %{"kind" => idle.kind, "connections_ended" => 0}

      assert [busy_entry] = removed_entries(busy)
      assert busy_entry.metadata["connections_ended"] == 2
      refute inspect(busy_entry.metadata) =~ busy.client_id
    end

    test "writes nothing for a client that was not there, and nothing without an actor", ctx do
      before = Repo.aggregate(Entry, :count)
      assert {:error, :not_found} = Clients.delete(UUIDv7.generate(), actor_uuid: ctx.user.uuid)
      assert Repo.aggregate(Entry, :count) == before

      client = client!()
      assert {:ok, _} = Clients.delete(client.uuid)
      assert removed_entries(client) == []
    end

    test "only_idle: refuses a client with a live connection and ends nothing", ctx do
      client = client!()
      seeded = seed_grant!(ctx.scope, client: client)

      assert {:error, :has_connections} =
               Clients.delete(client.uuid, actor_uuid: ctx.user.uuid, only_idle: true)

      assert Repo.get(PhoenixKit.API.OAuth.Client, client.uuid)
      assert Repo.get!(PhoenixKit.API.Keys.Key, seeded.key.uuid).revoked_at == nil
      assert removed_entries(client) == []
    end

    test "only_idle: a consent just approved, its code not yet exchanged, is a live connection",
         ctx do
      client = client!()
      attrs = %{scopes: [read_scope()], expires_at: DateTime.add(DateTime.utc_now(), 86_400)}
      {:ok, grant, key} = Grants.create(ctx.scope, client, attrs, impersonated: false)

      {:ok, _code, _row} =
        Codes.issue(grant, %{redirect_uri: "https://x/cb", code_challenge: "c"})

      assert grant.activated_at == nil

      assert {:error, :has_connections} =
               Clients.delete(client.uuid, actor_uuid: ctx.user.uuid, only_idle: true)

      assert Repo.get(PhoenixKit.API.OAuth.Client, client.uuid)
      assert Repo.get!(PhoenixKit.API.Keys.Key, key.uuid).revoked_at == nil
    end

    test "only_idle: a consent whose code ran out is not a connection", ctx do
      client = client!()
      attrs = %{scopes: [read_scope()], expires_at: DateTime.add(DateTime.utc_now(), 86_400)}
      {:ok, grant, _key} = Grants.create(ctx.scope, client, attrs, impersonated: false)
      {:ok, _code, row} = Codes.issue(grant, %{redirect_uri: "https://x/cb", code_challenge: "c"})

      Repo.update_all(from(c in PhoenixKit.API.OAuth.Code, where: c.uuid == ^row.uuid),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)]
      )

      assert {:ok, _} = Clients.delete(client.uuid, actor_uuid: ctx.user.uuid, only_idle: true)
    end

    test "only_idle: removes a client whose grants all ended", ctx do
      client = client!()
      ended = seed_grant!(ctx.scope, client: client)
      {:ok, _} = Grants.revoke(ended.grant)

      assert {:ok, _} = Clients.delete(client.uuid, actor_uuid: ctx.user.uuid, only_idle: true)
      assert Repo.get(PhoenixKit.API.OAuth.Client, client.uuid) == nil
    end
  end
end
