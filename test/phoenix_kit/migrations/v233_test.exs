defmodule PhoenixKit.Migrations.Postgres.V233Test do
  @moduledoc """
  V233's OAuth tables, run as the real SQL: the tables and the key column, a re-run and a
  round trip, the constraints the resource side leans on (one key per grant, unique hashes,
  the kind checks, the cascades), and that the manifest (`ExpectedSchema`) declares exactly
  what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V233
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo

  @tables ~w(phoenix_kit_api_oauth_clients phoenix_kit_api_oauth_requests
             phoenix_kit_api_oauth_grants phoenix_kit_api_oauth_codes phoenix_kit_api_oauth_tokens)

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp tables do
    query(
      """
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = ANY($1) ORDER BY table_name
      """,
      [@tables]
    )
    |> List.flatten()
  end

  defp key_column? do
    [[exists]] =
      query("""
      SELECT EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_schema = 'public' AND table_name = 'phoenix_kit_api_keys'
                       AND column_name = 'oauth_grant_uuid')
      """)

    exists
  end

  test "the chain is at 233 or later, with the tables and the key column" do
    assert String.to_integer(marker()) >= 233
    assert tables() == Enum.sort(@tables)
    assert key_column?()
  end

  test "rolls back, forward, and again without change" do
    run(V233.down_statements("public"))
    assert tables() == []
    refute key_column?()
    assert marker() == "232"

    run(V233.up_statements("public"))
    assert tables() == Enum.sort(@tables)
    assert key_column?()
    assert marker() == "233"

    run(V233.up_statements("public"))
    assert tables() == Enum.sort(@tables)
  end

  describe "the constraints" do
    defp user!, do: KeyTestSupport.register_user!()

    defp client! do
      [[uuid]] =
        query(
          "INSERT INTO phoenix_kit_api_oauth_clients (client_id, kind) VALUES ($1, 'preregistered') RETURNING uuid",
          ["https://client.example/#{System.unique_integer([:positive])}"]
        )

      uuid
    end

    defp key!(user) do
      [[uuid]] =
        query(
          """
          INSERT INTO phoenix_kit_api_keys (user_uuid, name, prefix, secret_hash, personal)
          VALUES ($1, 'k', $2, $3, true) RETURNING uuid
          """,
          [
            Ecto.UUID.dump!(user.uuid),
            Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
            :crypto.strong_rand_bytes(32)
          ]
        )

      uuid
    end

    defp grant!(user, client, key) do
      [[uuid]] =
        query(
          """
          INSERT INTO phoenix_kit_api_oauth_grants (user_uuid, client_uuid, key_uuid, resource, expires_at)
          VALUES ($1, $2, $3, 'https://x.example/mcp/admin', now() + interval '1 day') RETURNING uuid
          """,
          [Ecto.UUID.dump!(user.uuid), client, key]
        )

      uuid
    end

    test "a client id is unique" do
      id = "https://client.example/#{System.unique_integer([:positive])}"
      sql = "INSERT INTO phoenix_kit_api_oauth_clients (client_id, kind) VALUES ($1, 'dcr')"

      query(sql, [id])
      assert_raise Postgrex.Error, ~r/client_id_index/, fn -> query(sql, [id]) end
    end

    test "a request token hash and a code hash are unique" do
      user = user!()
      client = client!()
      grant = grant!(user, client, key!(user))
      hash = :crypto.strong_rand_bytes(32)

      request = """
      INSERT INTO phoenix_kit_api_oauth_requests
        (request_token_hash, client_uuid, redirect_uri, code_challenge, resource, expires_at)
      VALUES ($1, $2, 'https://c.example/cb', 'x', 'https://x.example/mcp/admin', now() + interval '10 minutes')
      """

      query(request, [hash, client])

      assert_raise Postgrex.Error, ~r/request_token_hash_index/, fn ->
        query(request, [hash, client])
      end

      code = """
      INSERT INTO phoenix_kit_api_oauth_codes (code_hash, grant_uuid, redirect_uri, code_challenge, expires_at)
      VALUES ($1, $2, 'https://c.example/cb', 'x', now() + interval '1 minute')
      """

      query(code, [hash, grant])
      assert_raise Postgrex.Error, ~r/code_hash_index/, fn -> query(code, [hash, grant]) end
    end

    test "a client's kind is checked" do
      assert_raise Postgrex.Error, ~r/kind_check/, fn ->
        query("INSERT INTO phoenix_kit_api_oauth_clients (client_id, kind) VALUES ('x', 'bogus')")
      end
    end

    test "one key belongs to one grant" do
      user = user!()
      client = client!()
      key = key!(user)
      grant!(user, client, key)

      assert_raise Postgrex.Error, ~r/unique/, fn -> grant!(user, client, key) end
    end

    test "a key's oauth_grant_uuid is unique where set, repeatable where null" do
      user = user!()
      key_a = key!(user)
      key_b = key!(user)
      key_c = key!(user)
      grant = Ecto.UUID.bingenerate()

      query("UPDATE phoenix_kit_api_keys SET oauth_grant_uuid = $1 WHERE uuid = $2", [
        grant,
        key_a
      ])

      assert_raise Postgrex.Error, ~r/oauth_grant_uuid_index/, fn ->
        query("UPDATE phoenix_kit_api_keys SET oauth_grant_uuid = $1 WHERE uuid = $2", [
          grant,
          key_b
        ])
      end

      # Two keys without a grant never collide.
      assert [[nil]] =
               query("SELECT oauth_grant_uuid FROM phoenix_kit_api_keys WHERE uuid = $1", [key_c])
    end

    test "a token's kind is checked, and its hash is unique" do
      user = user!()
      grant = grant!(user, client!(), key!(user))
      hash = :crypto.strong_rand_bytes(32)

      insert = fn kind, hash ->
        query(
          """
          INSERT INTO phoenix_kit_api_oauth_tokens (token_hash, kind, grant_uuid, family, expires_at)
          VALUES ($1, $2, $3, $4, now() + interval '1 hour')
          """,
          [hash, kind, grant, Ecto.UUID.bingenerate()]
        )
      end

      assert_raise Postgrex.Error, ~r/kind_check/, fn -> insert.("bogus", hash) end

      insert.("access", hash)
      assert_raise Postgrex.Error, ~r/unique/, fn -> insert.("refresh", hash) end
    end

    test "removing a user takes the key, the grant and its tokens and codes with it" do
      user = user!()
      grant = grant!(user, client!(), key!(user))

      query(
        """
        INSERT INTO phoenix_kit_api_oauth_tokens (token_hash, kind, grant_uuid, family, expires_at)
        VALUES ($1, 'access', $2, $3, now() + interval '1 hour')
        """,
        [:crypto.strong_rand_bytes(32), grant, Ecto.UUID.bingenerate()]
      )

      query(
        """
        INSERT INTO phoenix_kit_api_oauth_codes (code_hash, grant_uuid, redirect_uri, code_challenge, expires_at)
        VALUES ($1, $2, 'https://c.example/cb', 'x', now() + interval '1 minute')
        """,
        [:crypto.strong_rand_bytes(32), grant]
      )

      query("DELETE FROM phoenix_kit_users WHERE uuid = $1", [Ecto.UUID.dump!(user.uuid)])

      assert [[0]] =
               query("SELECT count(*) FROM phoenix_kit_api_oauth_grants WHERE uuid = $1", [grant])

      assert [[0]] =
               query("SELECT count(*) FROM phoenix_kit_api_oauth_tokens WHERE grant_uuid = $1", [
                 grant
               ])

      assert [[0]] =
               query("SELECT count(*) FROM phoenix_kit_api_oauth_codes WHERE grant_uuid = $1", [
                 grant
               ])
    end
  end

  describe "the manifest" do
    defp declared_by_v233 do
      Enum.filter(ExpectedSchema.objects("public"), fn object ->
        Enum.any?(object.revisions, &(elem(&1, 0) == 233))
      end)
    end

    test "declares the tables, the key column, their keys and indexes" do
      ids = MapSet.new(declared_by_v233(), & &1.id)

      for id <- [
            "table:phoenix_kit_api_oauth_clients",
            "table:phoenix_kit_api_oauth_requests",
            "table:phoenix_kit_api_oauth_grants",
            "table:phoenix_kit_api_oauth_codes",
            "table:phoenix_kit_api_oauth_tokens",
            "column:phoenix_kit_api_keys.oauth_grant_uuid",
            "column:phoenix_kit_api_oauth_grants.activated_at",
            "column:phoenix_kit_api_oauth_tokens.parent_uuid",
            "column:phoenix_kit_api_oauth_tokens.revoke_reason",
            "index:phoenix_kit_api_keys_oauth_grant_uuid_index",
            "index:phoenix_kit_api_oauth_clients_client_id_index",
            "index:phoenix_kit_api_oauth_requests_request_token_hash_index",
            "index:phoenix_kit_api_oauth_grants_key_uuid_index",
            "index:phoenix_kit_api_oauth_codes_code_hash_index",
            "index:phoenix_kit_api_oauth_tokens_token_hash_index"
          ] do
        assert id in ids, id
      end
    end

    test "what it declares matches what the chain built" do
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v233(),
            problem = problem(object, Probe.lookup(snapshot, object.check)),
            do: {object.id, problem}

      assert problems == []
    end

    defp problem(_object, nil), do: :missing

    defp problem(object, observed) do
      {_version, shape} = List.last(object.revisions)

      case Differ.compare(object.class, shape, observed) do
        :match ->
          nil

        {:mismatch, _} = mismatch ->
          if Differ.deparse_text_only?(mismatch), do: nil, else: mismatch
      end
    end
  end
end
