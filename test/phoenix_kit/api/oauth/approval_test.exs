defmodule PhoenixKit.API.OAuth.ApprovalTest do
  @moduledoc """
  The decision on a connection that waits for approval: who may list, approve and reject one,
  what a decision does to the grant, the status a person sees, the count in the status report and
  the daily clean-up that ends a connection nobody decided on.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Connections
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Prune
  alias PhoenixKit.API.OAuth.PruneWorker
  alias PhoenixKit.API.OAuth.Status
  alias PhoenixKit.API.OAuth.Token

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, role, scope} = oauth_holder(["media"])
    %{user: user, role: role, scope: scope, owner: scope_of(owner_user())}
  end

  defp waiting!(scope, opts \\ []), do: seed_grant!(scope, [approved?: false] ++ opts)

  defp grant(%{grant: %Grant{uuid: uuid}}), do: Repo.get!(Grant, uuid)

  defp age!(%{grant: %Grant{uuid: uuid}}, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(g in Grant, where: g.uuid == ^uuid), set: [inserted_at: at])
  end

  defp entries(action, grant_uuid) do
    Repo.all(from(e in Entry, where: e.action == ^action and e.resource_uuid == ^grant_uuid))
  end

  describe "Grants.approve/3" do
    test "refuses a borrowed session, and an option that does not say, before anything else",
         ctx do
      seeded = waiting!(ctx.scope)
      uuid = seeded.grant.uuid

      assert {:error, :impersonated} = Grants.approve(ctx.owner, uuid, impersonated: true)
      assert {:error, :impersonation_unknown} = Grants.approve(ctx.owner, uuid, [])
      assert {:error, :impersonation_unknown} = Grants.approve(ctx.owner, uuid, impersonated: nil)

      assert {:error, :impersonation_unknown} =
               Grants.approve(ctx.owner, uuid, impersonated: "no")

      assert {:error, :impersonation_unknown} = Grants.approve(ctx.owner, uuid, :nope)
      assert {:error, :impersonated} = Grants.approve(nil, "nope", impersonated: true)

      assert Grants.awaiting?(grant(seeded))
      assert entries("oauth.grant_approved", uuid) == []
    end

    test "approves a waiting connection once, and writes who decided", ctx do
      seeded = waiting!(ctx.scope)
      uuid = seeded.grant.uuid

      assert {:ok, %Grant{approved_at: %DateTime{}}} =
               Grants.approve(ctx.owner, uuid, impersonated: false)

      assert %DateTime{} = grant(seeded).approved_at
      refute Grants.awaiting?(grant(seeded))

      assert [entry] = entries("oauth.grant_approved", uuid)
      assert entry.actor_uuid == ctx.owner.user.uuid
      assert entry.metadata["owner_uuid"] == ctx.user.uuid
      assert entry.metadata["client_uuid"] == seeded.client.uuid
      assert entry.metadata["hosts"] == ["client.example"]

      secrets = [seeded.access, seeded.refresh]
      text = inspect(entry.metadata)
      for secret <- secrets, do: refute(text =~ secret)
      refute text =~ "https://client.example/callback"

      assert {:error, :not_pending} = Grants.approve(ctx.owner, uuid, impersonated: false)
      assert [_one] = entries("oauth.grant_approved", uuid)
    end

    test "names the host the connection answers to, not what the client's row says now", ctx do
      seeded = waiting!(ctx.scope)
      uuid = seeded.grant.uuid

      # The code was exchanged for this address; the document changed afterwards.
      Repo.update_all(Ecto.Query.from(g in Grant, where: g.uuid == ^uuid),
        set: [redirect_uri: "https://agent.example/cb?x=1"]
      )

      Repo.update_all(
        Ecto.Query.from(c in PhoenixKit.API.OAuth.Client, where: c.uuid == ^seeded.client.uuid),
        set: [redirect_uris: ["https://elsewhere.example/cb"]]
      )

      assert {:ok, _} = Grants.approve(ctx.owner, uuid, impersonated: false)
      assert [entry] = entries("oauth.grant_approved", uuid)
      assert entry.metadata["hosts"] == ["agent.example"]
      refute inspect(entry.metadata) =~ "x=1"
    end

    test "is an Owner's: an administrator with api, the person and nobody are refused", ctx do
      seeded = waiting!(ctx.scope)
      uuid = seeded.grant.uuid
      {admin, _role} = user_with(["media"])

      assert {:error, :forbidden} = Grants.approve(ctx.scope, uuid, impersonated: false)
      assert {:error, :forbidden} = Grants.approve(scope_of(admin), uuid, impersonated: false)
      assert {:error, :forbidden} = Grants.approve(nil, uuid, impersonated: false)
      assert Grants.awaiting?(grant(seeded))
      assert entries("oauth.grant_approved", uuid) == []
    end

    test "an unknown, malformed or someone else's uuid approves nothing", ctx do
      seeded = waiting!(ctx.scope)

      assert {:error, :not_pending} =
               Grants.approve(ctx.owner, Ecto.UUID.generate(), impersonated: false)

      assert {:error, :not_found} = Grants.approve(ctx.owner, "nope", impersonated: false)
      assert {:error, :not_found} = Grants.approve(ctx.owner, nil, impersonated: false)

      assert {:error, :not_pending} =
               Grants.approve(ctx.owner, seeded.key.uuid, impersonated: false)

      assert Grants.awaiting?(grant(seeded))
    end

    test "refuses a connection that is not activated, ended, expired or older than a week",
         ctx do
      inactive = waiting!(ctx.scope)

      Repo.update_all(from(g in Grant, where: g.uuid == ^inactive.grant.uuid),
        set: [activated_at: nil]
      )

      revoked = waiting!(ctx.scope)
      {:ok, _} = Grants.revoke(revoked.grant)

      expired = waiting!(ctx.scope)

      Repo.update_all(from(g in Grant, where: g.uuid == ^expired.grant.uuid),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      old = waiting!(ctx.scope)
      age!(old, Grants.approval_days() * 86_400 + 60)

      for seeded <- [inactive, revoked, expired, old] do
        assert {:error, :not_pending} =
                 Grants.approve(ctx.owner, seeded.grant.uuid, impersonated: false)

        assert Grants.awaiting?(grant(seeded))
      end
    end

    test "an approval that arrives after the revoke finds nothing to approve", ctx do
      seeded = waiting!(ctx.scope)
      {:ok, _} = Connections.revoke(ctx.scope, seeded.grant.uuid, :own)

      assert {:error, :not_pending} =
               Grants.approve(ctx.owner, seeded.grant.uuid, impersonated: false)

      assert grant(seeded).approved_at == nil
    end

    test "a revoke that arrives after the approval ends the approved connection", ctx do
      seeded = waiting!(ctx.scope)
      {:ok, _} = Grants.approve(ctx.owner, seeded.grant.uuid, impersonated: false)

      assert {:ok, %Grant{revoked_at: %DateTime{}}} =
               Connections.revoke(ctx.scope, seeded.grant.uuid, :own)
    end
  end

  describe "the ceiling of connections" do
    test "counts a connection that waits for approval", ctx do
      waiting!(ctx.scope)
      seed_grant!(ctx.scope)

      assert Grants.count_live(ctx.user.uuid) == 2
    end
  end

  describe "Connections.list_pending/1" do
    test "shows the waiting connections of everyone to an Owner, newest first", ctx do
      first = waiting!(ctx.scope)
      {_other, _role, other_scope} = oauth_holder(["media"])
      second = waiting!(other_scope)
      approved = seed_grant!(ctx.scope)

      uuids = ctx.owner |> Connections.list_pending() |> Enum.map(& &1.grant.uuid)

      assert uuids == [second.grant.uuid, first.grant.uuid]
      refute approved.grant.uuid in uuids

      assert [%{status: :awaiting_approval, owner: %{email: email}} | _] =
               Connections.list_pending(ctx.owner)

      assert email
    end

    test "leaves out what cannot be decided on", ctx do
      inactive = waiting!(ctx.scope)

      Repo.update_all(from(g in Grant, where: g.uuid == ^inactive.grant.uuid),
        set: [activated_at: nil]
      )

      revoked = waiting!(ctx.scope)
      {:ok, _} = Grants.revoke(revoked.grant)
      old = waiting!(ctx.scope)
      age!(old, Grants.approval_days() * 86_400 + 60)

      assert Connections.list_pending(ctx.owner) == []
    end

    test "is an Owner's alone", ctx do
      waiting!(ctx.scope)
      {admin, _role} = user_with(["media"])

      assert Connections.list_pending(ctx.scope) == []
      assert Connections.list_pending(scope_of(admin)) == []
      assert Connections.list_pending(nil) == []
    end
  end

  describe "Connections.reject/3" do
    test "refuses a borrowed session, and an option that does not say, before anything else",
         ctx do
      seeded = waiting!(ctx.scope)
      uuid = seeded.grant.uuid

      assert {:error, :impersonated} = Connections.reject(ctx.owner, uuid, impersonated: true)
      assert {:error, :impersonation_unknown} = Connections.reject(ctx.owner, uuid, [])

      assert {:error, :impersonation_unknown} =
               Connections.reject(ctx.owner, uuid, impersonated: 1)

      assert {:error, :impersonation_unknown} = Connections.reject(ctx.owner, uuid, :nope)

      assert grant(seeded).revoked_at == nil
      assert entries("oauth.grant_revoked", uuid) == []
    end

    test "ends the connection: its grant, its key and its tokens, with the reason", ctx do
      seeded = waiting!(ctx.scope)

      assert {:ok, %Grant{revoked_at: %DateTime{}}} =
               Connections.reject(ctx.owner, seeded.grant.uuid, impersonated: false)

      assert %DateTime{} = grant(seeded).revoked_at
      assert %Key{revoked_at: %DateTime{}} = Repo.get!(Key, seeded.key.uuid)

      reasons =
        Repo.all(
          from(t in Token, where: t.grant_uuid == ^seeded.grant.uuid, select: t.revoke_reason)
        )

      assert reasons != [] and Enum.all?(reasons, &(&1 == "approval_rejected"))

      assert [entry] = entries("oauth.grant_revoked", seeded.grant.uuid)
      assert entry.metadata["reason"] == "approval_rejected"
      assert entry.actor_uuid == ctx.owner.user.uuid
    end

    test "is an Owner's, and only for a connection that waits", ctx do
      seeded = waiting!(ctx.scope)
      approved = seed_grant!(ctx.scope)

      assert {:error, :forbidden} =
               Connections.reject(ctx.scope, seeded.grant.uuid, impersonated: false)

      assert {:error, :forbidden} =
               Connections.reject(nil, seeded.grant.uuid, impersonated: false)

      assert {:error, :not_found} =
               Connections.reject(ctx.owner, approved.grant.uuid, impersonated: false)

      assert {:error, :not_found} = Connections.reject(ctx.owner, "nope", impersonated: false)

      assert {:error, :not_found} =
               Connections.reject(ctx.owner, Ecto.UUID.generate(), impersonated: false)

      assert grant(seeded).revoked_at == nil
      assert grant(approved).revoked_at == nil
    end
  end

  describe "the status of a connection" do
    test "a waiting connection is awaiting_approval, in the person's list and the Owner's", ctx do
      waiting = waiting!(ctx.scope)
      approved = seed_grant!(ctx.scope)

      rows = Map.new(Connections.list(ctx.scope, :own), &{&1.grant.uuid, &1.status})
      assert rows[waiting.grant.uuid] == :awaiting_approval
      assert rows[approved.grant.uuid] == :active

      assert Enum.any?(Connections.list(ctx.owner, :all), &(&1.status == :awaiting_approval))
    end

    test "becomes active when the Owner approves it", ctx do
      seeded = waiting!(ctx.scope)
      {:ok, _} = Grants.approve(ctx.owner, seeded.grant.uuid, impersonated: false)

      assert [%{status: :active}] = Connections.list(ctx.scope, :own)
    end
  end

  describe "the status report" do
    test "counts the connections that wait and warns about them", ctx do
      assert %{waiting: 0, warnings: warnings} = Status.report()
      refute :approvals_waiting in warnings

      waiting!(ctx.scope)
      waiting!(ctx.scope)
      seed_grant!(ctx.scope)

      assert %{waiting: 2, warnings: warnings} = Status.report()
      assert :approvals_waiting in warnings
    end

    test "does not count a connection the Owner cannot decide on", ctx do
      old = waiting!(ctx.scope)
      age!(old, Grants.approval_days() * 86_400 + 60)

      assert Status.report().waiting == 0
    end
  end

  describe "Prune" do
    test "ends a connection nobody approved in a week, through the one revoke path", ctx do
      stale = waiting!(ctx.scope)
      age!(stale, Grants.approval_days() * 86_400 + 60)

      assert %{unapproved: 1} = Prune.run()

      assert %DateTime{} = grant(stale).revoked_at
      assert %Key{revoked_at: %DateTime{}} = Repo.get!(Key, stale.key.uuid)

      assert [entry] = entries("oauth.grant_revoked", stale.grant.uuid)
      assert entry.metadata["reason"] == "approval_timeout"

      assert %{unapproved: 0} = Prune.run()
    end

    test "leaves a recent waiting connection and every approved one", ctx do
      recent = waiting!(ctx.scope)
      age!(recent, 86_400)
      approved = seed_grant!(ctx.scope)
      age!(approved, Grants.approval_days() * 86_400 + 3_600)

      assert %{unapproved: 0} = Prune.run()

      assert grant(recent).revoked_at == nil
      assert grant(approved).revoked_at == nil
    end

    test "the daily worker runs the step", ctx do
      stale = waiting!(ctx.scope)
      age!(stale, Grants.approval_days() * 86_400 + 60)
      approved = seed_grant!(ctx.scope)
      age!(approved, Grants.approval_days() * 86_400 + 60)

      assert :ok = PruneWorker.perform(%Oban.Job{})

      assert grant(stale).revoked_at != nil
      assert grant(approved).revoked_at == nil
    end
  end
end
