defmodule PhoenixKit.Migrations.Postgres.V226Test do
  @moduledoc """
  V226's `phoenix_kit_api_keys.personal`, run as the real SQL: the column's shape, that
  existing keys read as not personal, a re-run and a round trip, and that the manifest
  (`ExpectedSchema`) declares exactly what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Postgres.V226
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
    SELECT data_type, column_default, is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'phoenix_kit_api_keys'
      AND column_name = 'personal'
    """)
  end

  # A key row written without naming the column, as every pre-V226 writer did.
  defp insert_key! do
    user = KeyTestSupport.register_user!()

    [[uuid]] =
      query(
        """
        INSERT INTO phoenix_kit_api_keys
          (name, prefix, secret_hash, user_uuid, created_by_uuid, inserted_at, updated_at)
        VALUES ('v226', $1, $2, $3, $3, now(), now())
        RETURNING uuid
        """,
        [
          Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
          :crypto.strong_rand_bytes(32),
          Ecto.UUID.dump!(user.uuid)
        ]
      )

    uuid
  end

  defp personal_of(uuid),
    do: query("SELECT personal FROM phoenix_kit_api_keys WHERE uuid = $1", [uuid])

  test "the chain is at 226 or later" do
    assert Postgres.current_version() >= 226
    assert String.to_integer(marker()) >= 226
  end

  test "the column is boolean, NOT NULL, default false" do
    assert [["boolean", "false", "NO"]] = column()
  end

  describe "the migration" do
    test "existing keys read as not personal" do
      run(V226.down_statements("public"))
      assert marker() == "225"
      uuid = insert_key!()

      run(V226.up_statements("public"))

      assert personal_of(uuid) == [[false]]
      assert marker() == "226"
    end

    test "running it again changes nothing" do
      uuid = insert_key!()
      query("UPDATE phoenix_kit_api_keys SET personal = true WHERE uuid = $1", [uuid])

      run(V226.up_statements("public"))

      assert personal_of(uuid) == [[true]]
      assert [["boolean", "false", "NO"]] = column()
    end

    test "rolls back and forward again" do
      run(V226.down_statements("public"))
      assert column() == []
      assert marker() == "225"

      run(V226.up_statements("public"))
      assert [["boolean", "false", "NO"]] = column()
      assert marker() == "226"
    end
  end

  describe "the manifest" do
    defp declared_by_v226 do
      for %{since: 226} = object <- ExpectedSchema.objects("public"), do: object
    end

    defp newest_shape(%{revisions: revisions}) do
      {_version, shape} = Enum.max_by(revisions, fn {version, _} -> version end)
      shape
    end

    test "declares the column, with the default as its backfill" do
      assert [%{id: "column:phoenix_kit_api_keys.personal", class: :column, backfill: :default}] =
               declared_by_v226()
    end

    test "what it declares matches what the chain built" do
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v226(),
            problem = problem(object, Probe.lookup(snapshot, object.check)),
            do: {object.id, problem}

      assert problems == []
    end

    defp problem(_object, nil), do: :missing

    defp problem(object, observed) do
      case Differ.compare(object.class, newest_shape(object), observed) do
        :match ->
          nil

        {:mismatch, _} = mismatch ->
          if Differ.deparse_text_only?(mismatch), do: nil, else: mismatch
      end
    end
  end
end
