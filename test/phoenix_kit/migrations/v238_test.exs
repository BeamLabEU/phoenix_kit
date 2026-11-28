defmodule PhoenixKit.Migrations.Postgres.V238Test do
  @moduledoc """
  V238's own rate limit on an API key, run as the real SQL: present, nullable and
  positive when set, a rollback and a re-run, the connection's lock_timeout left alone,
  and the manifest declaring it.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V238
  alias PhoenixKit.Test.Repo

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp column do
    query("""
    SELECT data_type, is_nullable FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_api_keys'
      AND column_name = 'rate_limit_per_minute'
    """)
  end

  test "the chain is at 238 or later, with a nullable integer rate_limit_per_minute" do
    assert String.to_integer(marker()) >= 238
    assert column() == [["integer", "YES"]]
  end

  test "a set limit must be positive (CHECK)" do
    assert [[definition]] =
             query("""
             SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c
             JOIN pg_class t ON t.oid = c.conrelid
             JOIN pg_namespace n ON n.oid = t.relnamespace
             WHERE c.conname = 'phoenix_kit_api_keys_rate_limit_per_minute_check'
               AND t.relname = 'phoenix_kit_api_keys' AND n.nspname = 'public'
             """)

    assert definition =~ "rate_limit_per_minute IS NULL"
    assert definition =~ "rate_limit_per_minute > 0"
  end

  test "rolls back, forward, and again without change" do
    run(V238.down_statements("public"))
    assert column() == []
    assert marker() == "237"

    run(V238.down_statements("public"))
    assert column() == []

    run(V238.up_statements("public"))
    assert column() == [["integer", "YES"]]
    assert marker() == "238"

    run(V238.up_statements("public"))
    assert column() == [["integer", "YES"]]
  end

  test "up and down leave the connection's lock_timeout as they found it" do
    %{rows: [[before]]} = Repo.query!("SHOW lock_timeout")

    run(V238.down_statements("public"))
    assert %{rows: [[^before]]} = Repo.query!("SHOW lock_timeout")

    run(V238.up_statements("public"))
    assert %{rows: [[^before]]} = Repo.query!("SHOW lock_timeout")
  end

  test "the manifest declares the column" do
    ids = "public" |> ExpectedSchema.objects() |> Enum.map(& &1.id)
    assert "column:phoenix_kit_api_keys.rate_limit_per_minute" in ids
  end
end
