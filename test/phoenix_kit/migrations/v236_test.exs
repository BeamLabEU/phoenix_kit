defmodule PhoenixKit.Migrations.Postgres.V236Test do
  @moduledoc """
  V236's handoff table, run as the real SQL: the table and its indexes, the unique token hash, the
  cascade from the account, a rollback, a re-run, and that the manifest (`ExpectedSchema`)
  declares what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V236
  alias PhoenixKit.Test.Repo

  @table "phoenix_kit_handoff_tokens"
  @indexes ~w(phoenix_kit_handoff_tokens_token_hash_index
              phoenix_kit_handoff_tokens_user_uuid_index
              phoenix_kit_handoff_tokens_expires_at_index
              phoenix_kit_handoff_tokens_source_proof_hash_index)

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp table_exists? do
    query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
      [@table]
    ) != []
  end

  defp indexes do
    query(
      "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)",
      [@indexes]
    )
    |> List.flatten()
    |> Enum.sort()
  end

  defp insert(hash, user_uuid \\ nil, source_proof_hash \\ nil) do
    query(
      """
      INSERT INTO phoenix_kit_handoff_tokens
        (token_hash, target_host, redirect_path, user_uuid, browser_nonce_hash, source_proof_hash,
         expires_at)
      VALUES ($1, 'shop.test', '/', $2, $3, $4, now() + interval '1 minute') RETURNING uuid
      """,
      [hash, user_uuid, :crypto.strong_rand_bytes(32), source_proof_hash]
    )
  end

  test "the chain is at 236 or later, with the table and its indexes" do
    assert String.to_integer(marker()) >= 236
    assert table_exists?()
    assert indexes() == Enum.sort(@indexes)
  end

  test "rolls back, forward, and again without change" do
    run(V236.down_statements("public"))
    refute table_exists?()
    assert marker() == "235"

    run(V236.down_statements("public"))
    refute table_exists?()

    run(V236.up_statements("public"))
    assert table_exists?()
    assert indexes() == Enum.sort(@indexes)
    assert marker() == "236"

    run(V236.up_statements("public"))
    assert table_exists?()
  end

  test "a token hash is unique, the payload defaults to an empty map, and the account cascades" do
    user = KeyTestSupport.register_user!()
    hash = :crypto.strong_rand_bytes(32)

    [[row]] = insert(hash, Ecto.UUID.dump!(user.uuid))
    assert_raise Postgrex.Error, fn -> insert(hash) end

    assert query("SELECT payload, used_at FROM phoenix_kit_handoff_tokens WHERE uuid = $1", [row]) ==
             [[%{}, nil]]

    query("DELETE FROM phoenix_kit_users WHERE uuid = $1", [Ecto.UUID.dump!(user.uuid)])
    assert query("SELECT count(*) FROM phoenix_kit_handoff_tokens") == [[0]]
  end

  test "a source proof is single use: unique where set, and any number of rows have none" do
    proof = :crypto.strong_rand_bytes(32)

    assert [[_uuid]] = insert(:crypto.strong_rand_bytes(32), nil, proof)

    error =
      assert_raise Postgrex.Error, fn -> insert(:crypto.strong_rand_bytes(32), nil, proof) end

    assert error.postgres.constraint == "phoenix_kit_handoff_tokens_source_proof_hash_index"

    assert [[_]] = insert(:crypto.strong_rand_bytes(32), nil, :crypto.strong_rand_bytes(32))
    assert [[_]] = insert(:crypto.strong_rand_bytes(32))
    assert [[_]] = insert(:crypto.strong_rand_bytes(32))
  end

  defp columns do
    query(
      "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1",
      [@table]
    )
    |> List.flatten()
  end

  test "a database that ran an earlier draft of V236 gets the columns and the index on a re-run" do
    run([
      "DROP INDEX phoenix_kit_handoff_tokens_source_proof_hash_index",
      "ALTER TABLE phoenix_kit_handoff_tokens DROP COLUMN source_proof_hash",
      "ALTER TABLE phoenix_kit_handoff_tokens DROP COLUMN source_session_uuid"
    ])

    refute "source_proof_hash" in columns()
    refute "source_session_uuid" in columns()

    run(V236.up_statements("public"))

    assert "source_proof_hash" in columns()
    assert "source_session_uuid" in columns()
    assert indexes() == Enum.sort(@indexes)

    assert [[_]] =
             insert(:crypto.strong_rand_bytes(32), nil, :crypto.strong_rand_bytes(32))
  end

  test "the session a row continues is a nullable uuid with no foreign key" do
    session = Ecto.UUID.bingenerate()
    [[row]] = insert(:crypto.strong_rand_bytes(32))

    query("UPDATE phoenix_kit_handoff_tokens SET source_session_uuid = $1 WHERE uuid = $2", [
      session,
      row
    ])

    assert query("SELECT source_session_uuid FROM phoenix_kit_handoff_tokens WHERE uuid = $1", [
             row
           ]) == [[session]]

    assert query("""
           SELECT count(*) FROM pg_constraint
           WHERE conrelid = 'phoenix_kit_handoff_tokens'::regclass AND contype = 'f'
             AND confrelid <> 'phoenix_kit_users'::regclass
           """) == [[0]]
  end

  test "a guest row (no account) is allowed" do
    assert [[_uuid]] = insert(:crypto.strong_rand_bytes(32))
  end

  test "the manifest declares the table as core's" do
    assert MapSet.member?(ExpectedSchema.created_table_names(), @table)
  end
end
