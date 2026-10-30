defmodule PhoenixKit.Migrations.Postgres.V219Test do
  @moduledoc """
  V219's API keys and service-user flag, run as the real SQL: the `api_only` column and its
  default, the keys table with its constraints and cascades, a re-run and a round trip, and
  that the manifest (`ExpectedSchema`) declares exactly what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.Fixtures, only: [user_fixture: 0]

  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V219
  alias PhoenixKit.Migrations.Postgres.V220
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth.User

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp key_attrs(user, overrides) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        user_uuid: user.uuid,
        name: "key #{n}",
        prefix: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0"),
        secret_hash: :crypto.hash(:sha256, "secret #{n}")
      },
      Map.new(overrides)
    )
  end

  defp insert_key(user, overrides \\ []) do
    Repo.insert(struct(Key, key_attrs(user, overrides)))
  end

  defp insert_key!(user, overrides), do: Repo.insert!(struct(Key, key_attrs(user, overrides)))

  describe "users.api_only" do
    test "the chain is at 219 or later, with a boolean that is NOT NULL and defaults to false" do
      assert String.to_integer(marker()) >= 219

      assert [["boolean", "false", "NO"]] =
               query("""
               SELECT data_type, column_default, is_nullable FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'phoenix_kit_users'
                 AND column_name = 'api_only'
               """)
    end

    test "every existing user reads false, and a new one is not a service user" do
      assert [] = query("SELECT 1 FROM public.phoenix_kit_users WHERE api_only")

      user = user_fixture()
      assert %User{api_only: false} = Repo.get!(User, user.uuid)
    end

    test "the schema loads and stores the flag" do
      user = user_fixture()
      {:ok, user} = user |> Ecto.Changeset.change(api_only: true) |> Repo.update()

      assert %User{api_only: true} = Repo.get!(User, user.uuid)
    end

    test "no changeset a form can reach sets it" do
      attrs = %{email: "svc@example.com", password: "ValidPassword123!", api_only: true}

      changesets = [
        User.registration_changeset(%User{}, attrs),
        User.email_changeset(%User{}, attrs),
        User.profile_changeset(%User{}, attrs),
        User.status_changeset(%User{}, attrs),
        User.password_changeset(%User{}, attrs)
      ]

      for changeset <- changesets do
        refute Map.has_key?(changeset.changes, :api_only)
      end
    end
  end

  describe "phoenix_kit_api_keys" do
    test "stores a key with the defaults of a plain one" do
      user = user_fixture()

      assert {:ok, key} = insert_key(user)
      key = Repo.get!(Key, key.uuid)

      assert key.user_uuid == user.uuid
      assert key.created_by_uuid == nil
      assert key.scopes == []
      assert key.allowed_ips == []
      assert key.requires_approval == false
      assert key.expires_at == nil
      assert key.revoked_at == nil
      assert key.last_used_at == nil
      assert key.inserted_at
    end

    test "round-trips scopes, allowed ips and timestamps" do
      user = user_fixture()
      expires = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

      {:ok, key} =
        insert_key(user,
          scopes: ["catalogue.products:read", "ecommerce.prices:write"],
          allowed_ips: ["10.0.0.0/8", "2001:db8::/32"],
          requires_approval: true,
          expires_at: expires
        )

      key = Repo.get!(Key, key.uuid)

      assert key.scopes == ["catalogue.products:read", "ecommerce.prices:write"]
      assert key.allowed_ips == ["10.0.0.0/8", "2001:db8::/32"]
      assert key.requires_approval
      assert key.expires_at == expires
    end

    test "the secret hash is left out when a key is inspected" do
      {:ok, key} = insert_key(user_fixture())

      refute inspect(key) =~ "secret_hash"
      refute inspect(key) =~ Base.encode16(key.secret_hash, case: :lower)
    end

    test "a prefix is unique" do
      user = user_fixture()
      {:ok, _} = insert_key(user, prefix: "0a1b2c3d")

      assert_raise Ecto.ConstraintError, ~r/phoenix_kit_api_keys_prefix_index/, fn ->
        insert_key!(user, prefix: "0a1b2c3d")
      end
    end

    test "a prefix is 8 lowercase hex characters" do
      user = user_fixture()

      for bad <- ["0A1B2C3D", "0a1b2c3", "0a1b2c3_", "0a1b-c3d", "g1234567"] do
        assert_raise Ecto.ConstraintError, ~r/phoenix_kit_api_keys_prefix_check/, fn ->
          insert_key!(user, prefix: bad)
        end
      end
    end

    test "the owner is required and must exist" do
      user = user_fixture()

      assert_raise Postgrex.Error, ~r/not_null_violation/, fn ->
        insert_key!(user, user_uuid: nil)
      end

      assert_raise Ecto.ConstraintError, ~r/phoenix_kit_api_keys_user_uuid_fkey/, fn ->
        insert_key!(user, user_uuid: Ecto.UUID.generate())
      end
    end

    test "deleting the owner deletes the key" do
      owner = user_fixture()
      {:ok, key} = insert_key(owner)

      Repo.delete!(owner)

      assert Repo.get(Key, key.uuid) == nil
    end

    test "deleting the person who issued a key keeps the key, with no issuer" do
      owner = user_fixture()
      issuer = user_fixture()
      {:ok, key} = insert_key(owner, created_by_uuid: issuer.uuid)

      Repo.delete!(issuer)

      assert %Key{created_by_uuid: nil} = Repo.get!(Key, key.uuid)
    end
  end

  describe "the migration" do
    test "running it again changes nothing" do
      user = user_fixture()
      {:ok, key} = insert_key(user)

      run(V219.up_statements("public"))
      run(V219.up_statements("public"))

      assert %Key{} = Repo.get!(Key, key.uuid)
      assert String.to_integer(marker()) >= 219
    end

    test "rolls back and forward again" do
      # V220's tables reference the keys table, so they go first and come back last.
      run(V220.down_statements("public"))
      run(V219.down_statements("public"))

      assert [[nil]] = query("SELECT to_regclass('public.phoenix_kit_api_keys')::text")

      assert [] =
               query("""
               SELECT 1 FROM information_schema.columns
               WHERE table_name = 'phoenix_kit_users' AND column_name = 'api_only'
               """)

      assert marker() == "218"

      run(V219.up_statements("public"))

      assert [["phoenix_kit_api_keys"]] =
               query("SELECT to_regclass('public.phoenix_kit_api_keys')::text")

      assert marker() == "219"

      run(V220.up_statements("public"))
    end
  end

  describe "the manifest" do
    defp declared_by_v219 do
      for %{since: 219} = object <- ExpectedSchema.objects("public"), do: object
    end

    defp newest_shape(%{revisions: revisions}) do
      {_version, shape} = Enum.max_by(revisions, fn {version, _} -> version end)
      shape
    end

    test "declares the column, the table, its 15 columns, 4 constraints and 3 indexes" do
      objects = declared_by_v219()
      by_class = Enum.frequencies_by(objects, & &1.class)

      assert %{table: 1, column: 16, constraint: 4, index: 3} = by_class
      assert length(objects) == 24
      assert "column:phoenix_kit_users.api_only" in Enum.map(objects, & &1.id)
      assert "table:phoenix_kit_api_keys" in Enum.map(objects, & &1.id)
    end

    test "every object it declares matches what the chain built" do
      assert declared_by_v219() != []
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v219(),
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

    # By V219 or a later version (V226 adds `personal`).
    test "every column of the table is declared, and nothing else is" do
      declared =
        for %{class: :column, id: "column:phoenix_kit_api_keys." <> name, since: since} <-
              ExpectedSchema.objects("public"),
            since >= 219,
            do: name

      actual =
        for [name] <-
              query("""
              SELECT column_name FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'phoenix_kit_api_keys'
              """),
            do: name

      assert Enum.sort(declared) == Enum.sort(actual)
    end
  end
end
