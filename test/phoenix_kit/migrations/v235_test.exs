defmodule PhoenixKit.Migrations.Postgres.V235Test do
  @moduledoc """
  V235's push tables, run as the real SQL: the three tables and their indexes, the cascades, a
  rollback, a re-run, and that the manifest (`ExpectedSchema`) declares what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V235
  alias PhoenixKit.Test.Repo

  @tables ~w(phoenix_kit_push_bindings phoenix_kit_push_installations phoenix_kit_push_pending)
  @indexes ~w(phoenix_kit_push_installations_endpoint_hash_index
              phoenix_kit_push_installations_browser_id_index
              phoenix_kit_push_bindings_installation_user_index
              phoenix_kit_push_bindings_user_uuid_index
              phoenix_kit_push_pending_user_uuid_index)

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp tables do
    query(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = ANY($1)",
      [@tables]
    )
    |> List.flatten()
    |> Enum.sort()
  end

  defp indexes do
    query(
      "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)",
      [@indexes]
    )
    |> List.flatten()
    |> Enum.sort()
  end

  test "the chain is at 235 or later, with the three tables and their indexes" do
    assert String.to_integer(marker()) >= 235
    assert tables() == @tables
    assert indexes() == Enum.sort(@indexes)
  end

  test "rolls back, forward, and again without change" do
    run(V235.down_statements("public"))
    assert tables() == []
    assert marker() == "234"

    run(V235.down_statements("public"))
    assert tables() == []

    run(V235.up_statements("public"))
    assert tables() == @tables
    assert indexes() == Enum.sort(@indexes)
    assert marker() == "235"

    run(V235.up_statements("public"))
    assert tables() == @tables
  end

  test "an endpoint is one installation; a binding is one per account; both cascade" do
    user = PhoenixKit.API.KeyTestSupport.register_user!()
    hash = :crypto.strong_rand_bytes(32)

    insert = fn ->
      query(
        """
        INSERT INTO phoenix_kit_push_installations (endpoint, endpoint_hash, p256dh, auth, vapid_key_id)
        VALUES ('https://fcm.googleapis.com/fcm/send/x', $1, 'p', 'a', 'k1') RETURNING uuid
        """,
        [hash]
      )
    end

    [[installation]] = insert.()
    assert_raise Postgrex.Error, insert

    bind = fn ->
      query(
        "INSERT INTO phoenix_kit_push_bindings (installation_uuid, user_uuid) VALUES ($1, $2)",
        [installation, Ecto.UUID.dump!(user.uuid)]
      )
    end

    bind.()
    assert_raise Postgrex.Error, bind

    query("DELETE FROM phoenix_kit_push_installations WHERE uuid = $1", [installation])
    assert query("SELECT count(*) FROM phoenix_kit_push_bindings") == [[0]]
  end

  test "the manifest declares the three tables as core's" do
    names = ExpectedSchema.created_table_names()
    for table <- @tables, do: assert(MapSet.member?(names, table))
  end
end
