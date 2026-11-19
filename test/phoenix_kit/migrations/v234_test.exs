defmodule PhoenixKit.Migrations.Postgres.V234Test do
  @moduledoc """
  V234's `approved_at` on the OAuth grants, run as the real SQL: the column, the backfill of the
  grants that exist (a waiting state did not exist before this version, so they all count as
  approved), a rollback that first ends every connection still waiting for approval (or it would
  turn into a working one), a re-run, and that the manifest (`ExpectedSchema`) declares what the
  chain builds. Also the review's additions: the grant's `redirect_uri`, the request's
  `network_hash` and the `expires_at` indexes of tokens and codes, added and dropped with it.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V234
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp column do
    query("""
    SELECT data_type, datetime_precision, is_nullable FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_api_oauth_grants'
      AND column_name = 'approved_at'
    """)
  end

  # The other shapes of V234: `{table, column}` => type, and the indexes.
  @columns [
    {"phoenix_kit_api_oauth_grants", "redirect_uri", "text"},
    {"phoenix_kit_api_oauth_requests", "network_hash", "bytea"}
  ]
  @indexes ~w(phoenix_kit_api_oauth_requests_network_hash_index
              phoenix_kit_api_oauth_tokens_expires_at_index
              phoenix_kit_api_oauth_codes_expires_at_index)

  defp added_columns do
    for {table, name, _type} <- @columns,
        [[type, nullable]] <- [
          query(
            """
            SELECT data_type, is_nullable FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
            """,
            [table, name]
          )
        ],
        do: {table, name, type, nullable}
  end

  defp indexes do
    query(
      "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)",
      [@indexes]
    )
    |> List.flatten()
    |> Enum.sort()
  end

  defp all_added?,
    do:
      added_columns() == Enum.map(@columns, fn {t, n, type} -> {t, n, type, "YES"} end) and
        indexes() == Enum.sort(@indexes)

  defp client! do
    [[uuid]] =
      query(
        "INSERT INTO phoenix_kit_api_oauth_clients (client_id, kind) VALUES ($1, 'preregistered') RETURNING uuid",
        ["https://client.example/#{System.unique_integer([:positive])}"]
      )

    uuid
  end

  # A grant with its hidden key and one live access token, in the state the columns say. The
  # `approved_at` column exists only while the chain is at 234, so it is written only when asked.
  defp grant!(user, client, opts \\ []) do
    [[key]] =
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

    [[grant]] =
      query(
        """
        INSERT INTO phoenix_kit_api_oauth_grants
          (user_uuid, client_uuid, key_uuid, resource, expires_at, activated_at, inserted_at)
        VALUES ($1, $2, $3, 'https://x.example/mcp/admin', now() + interval '1 day', $4,
                now() - interval '2 hours')
        RETURNING uuid
        """,
        [Ecto.UUID.dump!(user.uuid), client, key, Keyword.get(opts, :activated_at)]
      )

    query("UPDATE phoenix_kit_api_keys SET oauth_grant_uuid = $1 WHERE uuid = $2", [grant, key])

    query(
      """
      INSERT INTO phoenix_kit_api_oauth_tokens (token_hash, kind, grant_uuid, family, expires_at)
      VALUES ($1, 'access', $2, $3, now() + interval '1 hour')
      """,
      [:crypto.strong_rand_bytes(32), grant, Ecto.UUID.bingenerate()]
    )

    if Keyword.get(opts, :approved, true) and column() != [] do
      query("UPDATE phoenix_kit_api_oauth_grants SET approved_at = now() WHERE uuid = $1", [grant])
    end

    %{grant: grant, key: key}
  end

  defp state(%{grant: grant, key: key}) do
    [[grant_revoked, key_revoked, token_revoked, reason]] =
      query(
        """
        SELECT g.revoked_at IS NOT NULL, k.revoked_at IS NOT NULL, t.revoked_at IS NOT NULL,
               t.revoke_reason
        FROM phoenix_kit_api_oauth_grants g
        JOIN phoenix_kit_api_keys k ON k.uuid = $2
        JOIN phoenix_kit_api_oauth_tokens t ON t.grant_uuid = g.uuid
        WHERE g.uuid = $1
        """,
        [grant, key]
      )

    %{grant: grant_revoked, key: key_revoked, token: token_revoked, reason: reason}
  end

  test "the chain is at 234 or later, with a nullable approved_at and the review's additions" do
    assert String.to_integer(marker()) >= 234
    assert [["timestamp without time zone", 0, "YES"]] = column()
    assert all_added?()
  end

  test "rolls back, forward, and again without change" do
    run(V234.down_statements("public"))
    assert column() == []
    assert added_columns() == []
    assert indexes() == []
    assert marker() == "233"

    # A second down, with the column already gone, runs through (the guard of the DO block).
    run(V234.down_statements("public"))
    assert column() == []
    assert marker() == "233"

    run(V234.up_statements("public"))
    assert [["timestamp without time zone", 0, "YES"]] = column()
    assert all_added?()
    assert marker() == "234"

    run(V234.up_statements("public"))
    assert [["timestamp without time zone", 0, "YES"]] = column()
    assert all_added?()
  end

  test "the new indexes cover what the prune and the network count look up" do
    defs =
      query(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)",
        [@indexes]
      )
      |> Map.new(fn [name, definition] -> {name, definition} end)

    assert defs["phoenix_kit_api_oauth_tokens_expires_at_index"] =~
             "phoenix_kit_api_oauth_tokens USING btree (expires_at)"

    assert defs["phoenix_kit_api_oauth_codes_expires_at_index"] =~
             "phoenix_kit_api_oauth_codes USING btree (expires_at)"

    assert defs["phoenix_kit_api_oauth_requests_network_hash_index"] =~
             "phoenix_kit_api_oauth_requests USING btree (network_hash)"
  end

  test "going up counts every grant that exists as approved, from when it was activated or made" do
    user = KeyTestSupport.register_user!()
    client = client!()

    run(V234.down_statements("public"))

    activated =
      grant!(user, client, activated_at: ~N[2026-05-01 10:00:00])

    never_activated = grant!(user, client)

    run(V234.up_statements("public"))

    assert [[~N[2026-05-01 10:00:00]]] =
             query("SELECT approved_at FROM phoenix_kit_api_oauth_grants WHERE uuid = $1", [
               activated.grant
             ])

    # A consent nobody finished has no activation: the day it was made stands in.
    assert [[true]] =
             query(
               "SELECT approved_at = inserted_at FROM phoenix_kit_api_oauth_grants WHERE uuid = $1",
               [never_activated.grant]
             )
  end

  test "going up again does not move an approval, and leaves a waiting grant waiting" do
    user = KeyTestSupport.register_user!()
    client = client!()
    approved = grant!(user, client)
    waiting = grant!(user, client, approved: false)

    [[before]] =
      query("SELECT approved_at FROM phoenix_kit_api_oauth_grants WHERE uuid = $1", [
        approved.grant
      ])

    run(V234.up_statements("public"))

    assert [[^before]] =
             query("SELECT approved_at FROM phoenix_kit_api_oauth_grants WHERE uuid = $1", [
               approved.grant
             ])

    # `UPDATE ... WHERE approved_at IS NULL` of the backfill is for the run that adds the
    # column; a re-run over a chain already at 234 is told apart by the column existing, and a
    # grant that is waiting there stays waiting.
    assert [[nil]] =
             query("SELECT approved_at FROM phoenix_kit_api_oauth_grants WHERE uuid = $1", [
               waiting.grant
             ])
  end

  test "rolling back first ends the connections that wait, with their tokens and hidden keys" do
    user = KeyTestSupport.register_user!()
    client = client!()
    approved = grant!(user, client)
    waiting = grant!(user, client, approved: false)

    assert %{grant: false, key: false, token: false} = state(waiting)

    run(V234.down_statements("public"))

    assert column() == []

    assert %{grant: true, key: true, token: true, reason: reason} = state(waiting)
    assert reason == "migration_rollback"

    # What was approved goes on working.
    assert %{grant: false, key: false, token: false} = state(approved)
  end

  test "rolling back leaves a waiting grant that had ended before as it was" do
    user = KeyTestSupport.register_user!()
    client = client!()
    ended = grant!(user, client, approved: false)

    query(
      "UPDATE phoenix_kit_api_oauth_grants SET revoked_at = now() - interval '1 hour' WHERE uuid = $1",
      [ended.grant]
    )

    [[revoked_at]] =
      query("SELECT revoked_at FROM phoenix_kit_api_oauth_grants WHERE uuid = $1", [ended.grant])

    run(V234.down_statements("public"))

    assert [[^revoked_at]] =
             query("SELECT revoked_at FROM phoenix_kit_api_oauth_grants WHERE uuid = $1", [
               ended.grant
             ])
  end

  describe "the manifest" do
    defp declared_by_v234 do
      Enum.filter(ExpectedSchema.objects("public"), fn object ->
        Enum.any?(object.revisions, &(elem(&1, 0) == 234))
      end)
    end

    test "declares the new columns and indexes" do
      ids = MapSet.new(declared_by_v234(), & &1.id)
      assert "column:phoenix_kit_api_oauth_grants.approved_at" in ids
      assert "column:phoenix_kit_api_oauth_grants.redirect_uri" in ids
      assert "column:phoenix_kit_api_oauth_requests.network_hash" in ids

      for index <- @indexes, do: assert(("index:" <> index) in ids)
    end

    test "what it declares matches what the chain built" do
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v234(),
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
