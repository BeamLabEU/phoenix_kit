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
end
