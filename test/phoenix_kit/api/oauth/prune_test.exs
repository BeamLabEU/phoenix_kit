defmodule PhoenixKit.API.OAuth.PruneTest do
  @moduledoc """
  The daily clean-up of the OAuth tables: what goes, and above all what must stay (a live
  grant and its key, a grant that ended only a moment ago, a used refresh token before its grant
  is over, a client with an authorization in progress).
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Prune
  alias PhoenixKit.API.OAuth.PruneWorker
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.API.OAuth.Tokens

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, _role, scope} = oauth_holder(["media"])
    %{user: user, scope: scope}
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  defp ahead(seconds), do: ago(-seconds)

  defp insert_code!(grant, expires_at) do
    Repo.insert!(%Code{
      code_hash: :crypto.strong_rand_bytes(32),
      grant_uuid: grant.uuid,
      redirect_uri: "https://client.example/callback",
      code_challenge: "x",
      expires_at: expires_at
    })
  end

  defp insert_request!(client, expires_at, consumed_at \\ nil) do
    Repo.insert!(%Request{
      request_token_hash: :crypto.strong_rand_bytes(32),
      client_uuid: client.uuid,
      redirect_uri: "https://client.example/callback",
      code_challenge: "x",
      resource: "https://x.example/mcp/admin",
      expires_at: expires_at,
      consumed_at: consumed_at
    })
  end

  defp unfinished_grant!(scope, code_expired_ago) do
    client = client!()
    attrs = %{scopes: [read_scope()], expires_at: ahead(86_400)}
    {:ok, grant, key} = Grants.create(scope, client, attrs, impersonated: false)
    age(grant, 7200)
    code = insert_code!(grant, ago(code_expired_ago))
    {grant, key, code}
  end

  defp age(grant, seconds) do
    Repo.update_all(from(g in Grant, where: g.uuid == ^grant.uuid),
      set: [inserted_at: ago(seconds)]
    )
  end

  describe "consents nobody finished" do
    test "go with their hidden key, an hour after the code ran out", %{scope: scope} do
      {grant, key, code} = unfinished_grant!(scope, 3700)

      assert %{grants: 1} = Prune.run()

      assert Repo.get(Grant, grant.uuid) == nil
      assert Repo.get(Key, key.uuid) == nil
      assert Repo.get(Code, code.uuid) == nil
    end

    test "stay while the code is younger than the grace, or still alive", %{scope: scope} do
      {young, young_key, _} = unfinished_grant!(scope, 600)
      {live, live_key, _} = unfinished_grant!(scope, -30)

      assert %{grants: 0} = Prune.run()

      assert Repo.get(Grant, young.uuid)
      assert Repo.get(Key, young_key.uuid)
      assert Repo.get(Grant, live.uuid)
      assert Repo.get(Key, live_key.uuid)
    end

    test "a grant made a minute ago stays whatever its codes say", %{scope: scope} do
      client = client!()
      attrs = %{scopes: [read_scope()], expires_at: ahead(86_400)}
      {:ok, grant, _key} = Grants.create(scope, client, attrs, impersonated: false)

      assert %{grants: 0} = Prune.run()
      assert Repo.get(Grant, grant.uuid)
    end

    test "an activated grant and its key are not taken for an abandoned consent", %{scope: scope} do
      seed = seed_grant!(scope)
      age(seed.grant, 7200)
      insert_code!(seed.grant, ago(7200))
      {:ok, _} = Grants.revoke(seed.grant)

      assert %{grants: 0, ended: 0} = Prune.run()
      assert Repo.get(Grant, seed.grant.uuid)
      assert Repo.get(Key, seed.key.uuid).revoked_at
    end

    test "delete_unactivated/2 looks again under the lock: a grant activated meanwhile stays", %{
      scope: scope
    } do
      {grant, key, _code} = unfinished_grant!(scope, 3700)
      Repo.update_all(from(g in Grant, where: g.uuid == ^grant.uuid), set: [activated_at: ago(1)])

      assert Grants.delete_unactivated(grant.uuid, ago(3600)) == :kept
      assert Repo.get(Grant, grant.uuid)
      assert Repo.get(Key, key.uuid)
      assert Grants.delete_unactivated(UUIDv7.generate(), ago(3600)) == :kept
    end

    test "delete_unactivated/2 keeps a grant that already has a token", %{scope: scope} do
      {grant, key, _code} = unfinished_grant!(scope, 3700)
      {:ok, _token, _row} = Tokens.issue(grant, :access)

      assert Grants.delete_unactivated(grant.uuid, ago(3600)) == :kept
      assert Repo.get(Grant, grant.uuid)
      assert Repo.get(Key, key.uuid)
      assert Repo.exists?(from(t in Token, where: t.grant_uuid == ^grant.uuid))
    end
  end

  describe "grants that ended" do
    defp set_grant(grant, fields),
      do: Repo.update_all(from(g in Grant, where: g.uuid == ^grant.uuid), set: fields)

    test "go with their hidden key, tokens and codes, three days after they were revoked", %{
      scope: scope
    } do
      seed = seed_grant!(scope)
      code = insert_code!(seed.grant, ago(5))
      {:ok, _} = Grants.revoke(seed.grant)
      set_grant(seed.grant, revoked_at: ago(4 * 86_400))

      assert %{ended: 1} = Prune.run()

      assert Repo.get(Grant, seed.grant.uuid) == nil
      assert Repo.get(Key, seed.key.uuid) == nil
      assert Repo.get(Code, code.uuid) == nil
      assert Repo.get(Token, seed.access_row.uuid) == nil
      assert Repo.get(Token, seed.refresh_row.uuid) == nil
    end

    test "go three days after they ran out, revoked or not", %{scope: scope} do
      seed = seed_grant!(scope)
      set_grant(seed.grant, expires_at: ago(4 * 86_400))

      assert %{ended: 1} = Prune.run()
      assert Repo.get(Grant, seed.grant.uuid) == nil
      assert Repo.get(Key, seed.key.uuid) == nil
    end

    test "stay while their end is younger than the three days", %{scope: scope} do
      revoked = seed_grant!(scope)
      {:ok, _} = Grants.revoke(revoked.grant)
      set_grant(revoked.grant, revoked_at: ago(2 * 86_400))

      expired = seed_grant!(scope)
      set_grant(expired.grant, expires_at: ago(86_400))

      assert %{ended: 0} = Prune.run()

      for seed <- [revoked, expired] do
        assert Repo.get(Grant, seed.grant.uuid)
        assert Repo.get(Key, seed.key.uuid)
        assert Repo.get(Token, seed.access_row.uuid)
      end
    end

    test "a grant that is alive stays, however old", %{scope: scope} do
      seed = seed_grant!(scope)
      age(seed.grant, 400 * 86_400)

      assert %{grants: 0, ended: 0} = Prune.run()
      assert Repo.get(Grant, seed.grant.uuid)
      assert Repo.get(Key, seed.key.uuid)
    end

    test "a person's own key is never touched, however long it has been over", %{scope: scope} do
      attrs = %{name: "mine", scopes: [], expires_at: ahead(86_400)}
      {:ok, personal, _token} = Keys.create_personal_key(scope, attrs, impersonated: false)

      Repo.update_all(from(k in Key, where: k.uuid == ^personal.uuid),
        set: [revoked_at: ago(400 * 86_400), expires_at: ago(399 * 86_400)]
      )

      assert %{ended: 0} = Prune.run()
      assert Repo.get(Key, personal.uuid)
    end

    test "delete_ended/2 looks again under the lock: a grant that is not over stays", %{
      scope: scope
    } do
      seed = seed_grant!(scope)

      assert Grants.delete_ended(seed.grant.uuid, ago(3 * 86_400)) == :kept
      assert Grants.delete_ended(UUIDv7.generate(), ago(3 * 86_400)) == :kept
      assert Repo.get(Grant, seed.grant.uuid)
      assert Repo.get(Key, seed.key.uuid)

      set_grant(seed.grant, expires_at: ago(86_400))
      assert Grants.delete_ended(seed.grant.uuid, ago(3 * 86_400)) == :kept

      set_grant(seed.grant, expires_at: ago(4 * 86_400))
      assert Grants.delete_ended(seed.grant.uuid, ago(3 * 86_400)) == :deleted
      assert Repo.get(Grant, seed.grant.uuid) == nil
    end

    test "a run clears more than one batch", %{scope: scope} do
      seed = seed_grant!(scope)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # 520 more grants, each on its own hidden key row, all over for a week.
      for _ <- 1..520 do
        grant_uuid = UUIDv7.generate()

        {:ok, key} =
          %Key{
            user_uuid: seed.key.user_uuid,
            name: "OAuth: bulk",
            prefix: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
            secret_hash: :crypto.strong_rand_bytes(32),
            personal: true,
            oauth_grant_uuid: grant_uuid,
            scopes: [],
            expires_at: ago(7 * 86_400)
          }
          |> Repo.insert()

        Repo.insert!(%Grant{
          uuid: grant_uuid,
          user_uuid: key.user_uuid,
          client_uuid: seed.client.uuid,
          key_uuid: key.uuid,
          resource: "https://x.example/mcp/admin",
          scopes: [],
          expires_at: ago(7 * 86_400),
          inserted_at: now
        })
      end

      assert %{ended: 520} = Prune.run()
      assert Repo.get(Grant, seed.grant.uuid)
    end
  end

  describe "requests, codes and tokens" do
    test "removes what ran out and keeps the rest", %{scope: scope} do
      seed = seed_grant!(scope)
      client = seed.client

      old_request = insert_request!(client, ago(5))
      live_request = insert_request!(client, ahead(300))
      old_code = insert_code!(seed.grant, ago(5))
      live_code = insert_code!(seed.grant, ahead(30))

      Repo.update_all(from(t in Token, where: t.uuid == ^seed.access_row.uuid),
        set: [expires_at: ago(4 * 86_400)]
      )

      counts = Prune.run()

      assert counts.requests == 1 and counts.codes == 1 and counts.tokens == 1
      assert Repo.get(Request, old_request.uuid) == nil
      assert Repo.get(Request, live_request.uuid)
      assert Repo.get(Code, old_code.uuid) == nil
      assert Repo.get(Code, live_code.uuid)
      assert Repo.get(Token, seed.access_row.uuid) == nil
      assert Repo.get(Token, seed.refresh_row.uuid)
    end

    test "an access token that ended a moment ago stays: its client may still come back", %{
      scope: scope
    } do
      seed = seed_grant!(scope)

      Repo.update_all(from(t in Token, where: t.uuid == ^seed.access_row.uuid),
        set: [expires_at: ago(3600)]
      )

      assert %{tokens: 0} = Prune.run()
      assert Repo.get(Token, seed.access_row.uuid)
    end

    test "a run clears more than one batch of every kind", %{scope: scope} do
      seed = seed_grant!(scope)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      token_rows =
        for _ <- 1..620 do
          %{
            uuid: UUIDv7.generate(),
            token_hash: :crypto.strong_rand_bytes(32),
            kind: "access",
            grant_uuid: seed.grant.uuid,
            family: UUIDv7.generate(),
            expires_at: ago(10 * 86_400),
            inserted_at: now
          }
        end

      code_rows =
        for _ <- 1..620 do
          %{
            uuid: UUIDv7.generate(),
            code_hash: :crypto.strong_rand_bytes(32),
            grant_uuid: seed.grant.uuid,
            redirect_uri: "https://client.example/callback",
            code_challenge: "x",
            expires_at: ago(5),
            inserted_at: now
          }
        end

      request_rows =
        for _ <- 1..620 do
          %{
            uuid: UUIDv7.generate(),
            request_token_hash: :crypto.strong_rand_bytes(32),
            client_uuid: seed.client.uuid,
            redirect_uri: "https://client.example/callback",
            code_challenge: "x",
            resource: "https://x.example/mcp/admin",
            expires_at: ago(5),
            inserted_at: now
          }
        end

      for {schema, rows} <- [{Token, token_rows}, {Code, code_rows}, {Request, request_rows}] do
        rows |> Enum.chunk_every(200) |> Enum.each(&Repo.insert_all(schema, &1))
      end

      counts = Prune.run()

      assert counts.tokens == 620 and counts.codes == 620 and counts.requests == 620
      assert Repo.aggregate(from(t in Token, where: t.expires_at < ^ago(86_400)), :count) == 0
    end

    test "a used refresh token stays until its grant is over", %{scope: scope} do
      seed = seed_grant!(scope)

      Repo.update_all(from(t in Token, where: t.uuid == ^seed.refresh_row.uuid),
        set: [used_at: ago(86_400), revoked_at: ago(86_400), revoke_reason: "rotated"]
      )

      assert %{tokens: 0} = Prune.run()
      assert Repo.get(Token, seed.refresh_row.uuid)
    end
  end

  describe "registered clients" do
    defp dcr_client!(age_seconds) do
      client = client!(%{client_name: "registered"})

      Repo.update_all(from(c in Client, where: c.uuid == ^client.uuid),
        set: [kind: "dcr", inserted_at: ago(age_seconds)]
      )

      client
    end

    test "with no grant go a day after they registered", %{} do
      old = dcr_client!(90_000)
      fresh = dcr_client!(3600)

      assert %{clients: 1} = Prune.run()
      assert Repo.get(Client, old.uuid) == nil
      assert Repo.get(Client, fresh.uuid)
    end

    test "with an authorization in progress, or a grant, stay", %{scope: scope} do
      waiting = dcr_client!(90_000)
      insert_request!(waiting, ahead(300))

      with_grant = dcr_client!(90_000)
      attrs = %{scopes: [read_scope()], expires_at: ahead(86_400)}
      {:ok, _grant, _key} = Grants.create(scope, with_grant, attrs, impersonated: false)

      assert %{clients: 0} = Prune.run()
      assert Repo.get(Client, waiting.uuid)
      assert Repo.get(Client, with_grant.uuid)
    end

    test "pre-registered clients are never removed", %{} do
      client = client!()

      Repo.update_all(from(c in Client, where: c.uuid == ^client.uuid),
        set: [inserted_at: ago(900_000)]
      )

      assert %{clients: 0} = Prune.run()
      assert Repo.get(Client, client.uuid)
    end

    test "a client freed by an abandoned consent goes in the same run", %{scope: scope} do
      client = dcr_client!(90_000)
      attrs = %{scopes: [read_scope()], expires_at: ahead(86_400)}
      {:ok, grant, _key} = Grants.create(scope, client, attrs, impersonated: false)
      age(grant, 7200)
      insert_code!(grant, ago(3700))

      assert %{grants: 1, clients: 1} = Prune.run()
      assert Repo.get(Client, client.uuid) == nil
    end
  end

  test "the worker runs it", %{scope: scope} do
    {grant, key, _code} = unfinished_grant!(scope, 3700)
    ended = seed_grant!(scope)
    {:ok, _} = Grants.revoke(ended.grant)

    Repo.update_all(from(g in Grant, where: g.uuid == ^ended.grant.uuid),
      set: [revoked_at: ago(4 * 86_400)]
    )

    assert :ok = PruneWorker.perform(%Oban.Job{})

    assert Repo.get(Grant, grant.uuid) == nil
    assert Repo.get(Key, key.uuid) == nil
    assert Repo.get(Grant, ended.grant.uuid) == nil
  end
end
