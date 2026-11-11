defmodule PhoenixKit.Migrations.Postgres.V231Test do
  @moduledoc """
  V231's passkeys table, run as the real SQL: the table, a re-run and a round trip,
  the cascade and the unique credential, and that the manifest (`ExpectedSchema`)
  declares exactly what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V231
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp table? do
    [[exists]] =
      query("""
      SELECT EXISTS (SELECT 1 FROM information_schema.tables
                     WHERE table_schema = 'public' AND table_name = 'phoenix_kit_user_passkeys')
      """)

    exists
  end

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        email: "v231_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp insert(user, credential_id) do
    Repo.query!(
      """
      INSERT INTO phoenix_kit_user_passkeys (user_uuid, credential_id, public_key, rp_id, name)
      VALUES ($1, $2, $3, 'localhost', 'Test')
      """,
      [Ecto.UUID.dump!(user.uuid), credential_id, <<1, 2, 3>>]
    )
  end

  test "the chain is at 231 or later, with the table" do
    assert String.to_integer(marker()) >= 231
    assert table?()
  end

  test "rolls back, forward, and again without change" do
    run(V231.down_statements("public"))
    refute table?()
    assert marker() == "230"

    run(V231.up_statements("public"))
    assert table?()
    assert marker() == "231"

    run(V231.up_statements("public"))
    assert table?()
  end

  test "a credential belongs to one passkey" do
    user = user()
    insert(user, <<9, 9, 9>>)

    assert_raise Postgrex.Error, ~r/phoenix_kit_user_passkeys_credential_id_index/, fn ->
      Repo.transaction(fn -> insert(user(), <<9, 9, 9>>) end)
    end
  end

  test "a deleted user takes their passkeys with them" do
    user = user()
    insert(user, <<7, 7, 7>>)

    Repo.query!("DELETE FROM phoenix_kit_users WHERE uuid = $1", [Ecto.UUID.dump!(user.uuid)])

    assert [[0]] =
             query("SELECT count(*) FROM phoenix_kit_user_passkeys WHERE credential_id = $1", [
               <<7, 7, 7>>
             ])
  end

  describe "the manifest" do
    defp declared_by_v231 do
      Enum.filter(ExpectedSchema.objects("public"), fn object ->
        Enum.any?(object.revisions, &(elem(&1, 0) == 231))
      end)
    end

    test "declares the table, its keys and its indexes" do
      ids = MapSet.new(declared_by_v231(), & &1.id)

      for id <- [
            "table:phoenix_kit_user_passkeys",
            "column:phoenix_kit_user_passkeys.credential_id",
            "column:phoenix_kit_user_passkeys.rp_id",
            "index:phoenix_kit_user_passkeys_credential_id_index",
            "index:phoenix_kit_user_passkeys_user_uuid_index",
            "constraint:phoenix_kit_user_passkeys.phoenix_kit_user_passkeys_pkey",
            "constraint:phoenix_kit_user_passkeys.phoenix_kit_user_passkeys_user_uuid_fkey"
          ] do
        assert id in ids, id
      end
    end

    test "what it declares matches what the chain built" do
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v231(),
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
