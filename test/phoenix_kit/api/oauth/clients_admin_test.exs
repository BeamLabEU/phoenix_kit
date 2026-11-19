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

    test "added and connected clients come before newer ones nobody uses", ctx do
      connected = client!()
      added = client!()

      Repo.update_all(
        from(c in PhoenixKit.API.OAuth.Client, where: c.uuid in ^[connected.uuid, added.uuid]),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -7200) |> DateTime.truncate(:second)]
      )

      Repo.update_all(
        from(c in PhoenixKit.API.OAuth.Client, where: c.uuid == ^connected.uuid),
        set: [kind: "cimd"]
      )

      seed_grant!(ctx.scope, client: connected)

      # A flood of newer clients that name themselves, none of them in use.
      flood =
        for n <- 1..3 do
          Repo.insert!(%PhoenixKit.API.OAuth.Client{
            kind: "cimd",
            client_id: "https://flood.example/#{System.unique_integer([:positive])}/#{n}",
            redirect_uris: ["https://flood.example/cb"]
          })
        end

      order = Enum.map(Clients.list(), & &1.client.uuid)
      index = fn uuid -> Enum.find_index(order, &(&1 == uuid)) end

      assert index.(added.uuid) < index.(connected.uuid)
      for row <- flood, do: assert(index.(connected.uuid) < index.(row.uuid))
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

      attrs = %{
        scopes: [read_scope()],
        expires_at: DateTime.add(DateTime.utc_now(), 86_400),
        approved?: true
      }

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

    test "writes who typed the client in, with the redirect hosts and no path" do
      owner = owner_user()

      attrs = %{
        client_id: "claude-#{System.unique_integer([:positive])}",
        client_name: "Claude",
        redirect_uris: [
          "https://claude.ai/api/mcp/auth_callback?secret=abc",
          "https://claude.ai/other"
        ]
      }

      assert {:ok, client} = Clients.register_preregistered(scope_of(owner), attrs)

      assert [entry] = entries(client)
      assert entry.actor_uuid == owner.uuid
      assert entry.permanent
      assert entry.metadata == %{"kind" => "preregistered", "redirect_hosts" => ["claude.ai"]}
      refute inspect(entry.metadata) =~ "secret"
    end

    test "writes nothing for the system, and nothing for a refused client" do
      {:ok, client} =
        Clients.register_preregistered(:system, %{
          client_id: "plain-#{System.unique_integer([:positive])}"
        })

      assert entries(client) == []

      before = Repo.aggregate(Entry, :count)

      assert {:error, %Ecto.Changeset{}} =
               Clients.register_preregistered(scope_of(owner_user()), %{
                 client_id: "",
                 redirect_uris: []
               })

      assert Repo.aggregate(Entry, :count) == before
    end

    # A forged call: the page refuses anyone but an Owner, and so does the context.
    test "anyone but an Owner who holds api is refused and nothing is written", ctx do
      {admin, _role} = user_with([])
      before = Repo.aggregate(PhoenixKit.API.OAuth.Client, :count)

      for scope <- [scope_of(admin), ctx.scope, nil] do
        assert {:error, :forbidden} =
                 Clients.register_preregistered(scope, %{
                   client_id: "forged-#{System.unique_integer([:positive])}",
                   redirect_uris: ["https://evil.example/cb"]
                 })
      end

      assert Repo.aggregate(PhoenixKit.API.OAuth.Client, :count) == before
    end
  end

  describe "delete/3" do
    defp removed_entries(client) do
      Repo.all(
        from(e in Entry,
          where: e.action == "oauth.client_removed" and e.resource_uuid == ^client.uuid
        )
      )
    end

    defp admin_scope do
      {admin, _role} = user_with([])
      scope_of(admin)
    end

    test "an Owner: writes who removed the client and how many connections ended, even with none",
         ctx do
      owner = owner_user()
      idle = client!()
      busy = client!()
      seed_grant!(ctx.scope, client: busy)
      seed_grant!(ctx.scope, client: busy)

      assert {:ok, _} = Clients.delete(scope_of(owner), idle.uuid)
      assert {:ok, _} = Clients.delete(scope_of(owner), busy.uuid)

      assert [idle_entry] = removed_entries(idle)
      assert idle_entry.actor_uuid == owner.uuid
      assert idle_entry.permanent
      assert idle_entry.metadata == %{"kind" => idle.kind, "connections_ended" => 0}

      assert [busy_entry] = removed_entries(busy)
      assert busy_entry.metadata["connections_ended"] == 2
      refute inspect(busy_entry.metadata) =~ busy.client_id
    end

    test "writes nothing for a client that was not there, and nothing for the system" do
      before = Repo.aggregate(Entry, :count)
      assert {:error, :not_found} = Clients.delete(scope_of(owner_user()), UUIDv7.generate())
      assert Repo.aggregate(Entry, :count) == before

      client = client!()
      assert {:ok, _} = Clients.delete(:system, client.uuid)
      assert removed_entries(client) == []
    end

    test "a person without api is refused, whatever the client", ctx do
      client = client!()
      assert {:error, :forbidden} = Clients.delete(ctx.scope, client.uuid)
      assert {:error, :forbidden} = Clients.delete(nil, client.uuid)
      assert Repo.get(PhoenixKit.API.OAuth.Client, client.uuid)
    end

    test "the system ends connections only when it says so", ctx do
      client = client!()
      seeded = seed_grant!(ctx.scope, client: client)

      assert {:error, :has_connections} = Clients.delete(:system, client.uuid)
      assert Repo.get!(PhoenixKit.API.Keys.Key, seeded.key.uuid).revoked_at == nil

      assert {:ok, _} = Clients.delete(:system, client.uuid, end_connections: true)
      assert Repo.get!(PhoenixKit.API.Keys.Key, seeded.key.uuid).revoked_at
    end

    # A forged call: an option cannot make a person who is not an Owner end other people's
    # connections.
    test "not an Owner: refuses a client with a live connection and ends nothing", ctx do
      client = client!()
      seeded = seed_grant!(ctx.scope, client: client)

      assert {:error, :has_connections} =
               Clients.delete(admin_scope(), client.uuid, end_connections: true)

      assert Repo.get(PhoenixKit.API.OAuth.Client, client.uuid)
      assert Repo.get!(PhoenixKit.API.Keys.Key, seeded.key.uuid).revoked_at == nil
      assert removed_entries(client) == []
    end

    test "not an Owner: a consent just approved, its code not yet exchanged, is a live connection",
         ctx do
      client = client!()

      attrs = %{
        scopes: [read_scope()],
        expires_at: DateTime.add(DateTime.utc_now(), 86_400),
        approved?: true
      }

      {:ok, grant, key} = Grants.create(ctx.scope, client, attrs, impersonated: false)

      {:ok, _code, _row} =
        Codes.issue(grant, %{redirect_uri: "https://x/cb", code_challenge: "c"})

      assert grant.activated_at == nil

      assert {:error, :has_connections} = Clients.delete(admin_scope(), client.uuid)

      assert Repo.get(PhoenixKit.API.OAuth.Client, client.uuid)
      assert Repo.get!(PhoenixKit.API.Keys.Key, key.uuid).revoked_at == nil
    end

    test "not an Owner: a consent whose code ran out is not a connection", ctx do
      client = client!()

      attrs = %{
        scopes: [read_scope()],
        expires_at: DateTime.add(DateTime.utc_now(), 86_400),
        approved?: true
      }

      {:ok, grant, _key} = Grants.create(ctx.scope, client, attrs, impersonated: false)
      {:ok, _code, row} = Codes.issue(grant, %{redirect_uri: "https://x/cb", code_challenge: "c"})

      Repo.update_all(from(c in PhoenixKit.API.OAuth.Code, where: c.uuid == ^row.uuid),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)]
      )

      assert {:ok, _} = Clients.delete(admin_scope(), client.uuid)
    end

    test "not an Owner: removes a client whose grants all ended", ctx do
      client = client!()
      ended = seed_grant!(ctx.scope, client: client)
      {:ok, _} = Grants.revoke(ended.grant)

      assert {:ok, _} = Clients.delete(admin_scope(), client.uuid)
      assert Repo.get(PhoenixKit.API.OAuth.Client, client.uuid) == nil
    end
  end
end
