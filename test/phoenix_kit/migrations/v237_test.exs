defmodule PhoenixKit.Migrations.Postgres.V237Test do
  @moduledoc """
  V237's watermark column on the variant sets, run as the real SQL: present and
  nullable, a rollback and a re-run, the connection's lock_timeout left alone, and
  the manifest declaring it.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V237
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
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_variant_sets'
      AND column_name = 'watermark'
    """)
  end

  test "the chain is at 237 or later, with a nullable jsonb watermark" do
    assert String.to_integer(marker()) >= 237
    assert column() == [["jsonb", "YES"]]
  end

  test "rolls back, forward, and again without change" do
    run(V237.down_statements("public"))
    assert column() == []
    assert marker() == "236"

    run(V237.down_statements("public"))
    assert column() == []

    run(V237.up_statements("public"))
    assert column() == [["jsonb", "YES"]]
    assert marker() == "237"

    run(V237.up_statements("public"))
    assert column() == [["jsonb", "YES"]]
  end

  test "up and down leave the connection's lock_timeout as they found it" do
    %{rows: [[before]]} = Repo.query!("SHOW lock_timeout")

    run(V237.down_statements("public"))
    assert %{rows: [[^before]]} = Repo.query!("SHOW lock_timeout")

    run(V237.up_statements("public"))
    assert %{rows: [[^before]]} = Repo.query!("SHOW lock_timeout")
  end

  test "the manifest declares the column" do
    ids = "public" |> ExpectedSchema.objects() |> Enum.map(& &1.id)
    assert "column:phoenix_kit_variant_sets.watermark" in ids
  end
end
