defmodule PhoenixKit.Migrations.Postgres.V229Test do
  @moduledoc """
  V229's relationship types and roles on an acting link, run as the real SQL: what an
  existing grant becomes, a round trip, the guards the schema itself gives, and that
  the manifest (`ExpectedSchema`) declares exactly what the chain builds.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V229
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagerRole
  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)
  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp table?(name) do
    [[exists]] =
      query(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1)",
        [name]
      )

    exists
  end

  defp column?(table, name) do
    [[exists]] =
      query(
        """
        SELECT EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2)
        """,
        [table, name]
      )

    exists
  end

  defp role(name \\ "Buyer") do
    {:ok, role} =
      Roles.create_role(%{name: "#{name} #{System.unique_integer([:positive])}"})

    role
  end

  test "the chain is at 229 or later" do
    assert String.to_integer(marker()) >= 229
  end

  test "the seeded type has the uuid the application names" do
    assert %RelationshipType{
             key: "manager",
             can_act: true,
             can_manage: true,
             from_kind: "person",
             to_kind: "organization",
             status: "active",
             builtin: true
           } = Repo.get(RelationshipType, RelationshipType.manager_uuid())
  end

  test "a staff level exists with no setup" do
    assert %RelationshipType{can_act: true, can_manage: false, builtin: true} =
             Repo.get_by(RelationshipType, key: "staff")
  end

  test "a grant written without a type is a manager link with all roles" do
    s = Fixtures.acting_session()
    manager_uuid = RelationshipType.manager_uuid()

    assert %OrganizationManager{relationship_type_uuid: ^manager_uuid, all_roles: true} =
             Repo.get(OrganizationManager, s.manager.uuid)

    [[type, all_roles]] =
      query(
        "SELECT relationship_type_uuid::text, all_roles FROM phoenix_kit_organization_managers WHERE uuid = $1",
        [Ecto.UUID.dump!(s.manager.uuid)]
      )

    assert {type, all_roles} == {manager_uuid, true}
  end

  test "rolls back, forward, and again without change" do
    run(V229.down_statements("public"))
    refute table?("phoenix_kit_relationship_types")
    refute table?("phoenix_kit_organization_manager_roles")
    refute column?("phoenix_kit_organization_managers", "all_roles")
    refute column?("phoenix_kit_organization_invitations", "role_uuids")
    refute column?("phoenix_kit_user_roles", "data")
    assert marker() == "228"

    run(V229.up_statements("public"))
    assert table?("phoenix_kit_relationship_types")
    assert column?("phoenix_kit_user_roles", "data")
    assert marker() == "229"

    run(V229.up_statements("public"))
    assert [[2]] = query("SELECT count(*)::int FROM phoenix_kit_relationship_types")
  end

  test "a pending manager invitation from before V229 becomes a manager invitation" do
    s = Fixtures.acting_session()
    run(V229.down_statements("public"))

    query(
      """
      INSERT INTO phoenix_kit_organization_invitations
        (email, kind, status, token, expires_at, organization_uuid, inserted_at, updated_at)
      VALUES ('old@example.com', 'manager', 'pending', 'tok', now() + interval '1 day', $1, now(), now())
      """,
      [Ecto.UUID.dump!(s.organization.uuid)]
    )

    run(V229.up_statements("public"))

    assert [[type, true, []]] =
             query("""
             SELECT relationship_type_uuid::text, all_roles, role_uuids
             FROM phoenix_kit_organization_invitations WHERE email = 'old@example.com'
             """)

    assert type == RelationshipType.manager_uuid()
  end

  describe "what the schema refuses" do
    test "a role on a link cannot be deleted, and a link takes its role rows with it" do
      s = Fixtures.acting_session()
      role = role()

      row =
        Repo.insert!(%OrganizationManagerRole{
          organization_manager_uuid: s.manager.uuid,
          role_uuid: role.uuid
        })

      assert_raise Postgrex.Error, ~r/restrict_violation/, fn ->
        Repo.transaction(fn ->
          query("DELETE FROM phoenix_kit_user_roles WHERE uuid = $1", [Ecto.UUID.dump!(role.uuid)])
        end)
      end

      Repo.delete!(s.manager)
      refute Repo.get(OrganizationManagerRole, row.uuid)
      assert Repo.get(Role, role.uuid)
    end

    test "a link holds a role once" do
      s = Fixtures.acting_session()
      role = role()
      attrs = %{organization_manager_uuid: s.manager.uuid, role_uuid: role.uuid}

      Repo.insert!(struct(OrganizationManagerRole, attrs))

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(struct(OrganizationManagerRole, attrs), mode: :savepoint)
      end
    end

    test "a type in use cannot be deleted" do
      s = Fixtures.acting_session()

      assert_raise Postgrex.Error, ~r/restrict_violation/, fn ->
        Repo.transaction(fn ->
          query("DELETE FROM phoenix_kit_relationship_types WHERE uuid = $1", [
            Ecto.UUID.dump!(s.manager.relationship_type_uuid)
          ])
        end)
      end
    end

    test "a type cannot manage without acting, nor act except a person for an organization" do
      for {name, values} <- [
            {"phoenix_kit_relationship_types_manage_check",
             "'a', 'person', 'organization', false, true"},
            {"phoenix_kit_relationship_types_act_check",
             "'b', 'organization', 'organization', true, false"}
          ] do
        assert_raise Postgrex.Error, ~r/#{name}/, fn ->
          Repo.transaction(fn ->
            query("""
            INSERT INTO phoenix_kit_relationship_types (key, from_kind, to_kind, can_act, can_manage)
            VALUES (#{values})
            """)
          end)
        end
      end
    end

    test "a manager invitation needs a type and a member invitation has none" do
      s = Fixtures.acting_session()
      org = Ecto.UUID.dump!(s.organization.uuid)

      insert = fn kind, type ->
        query(
          """
          INSERT INTO phoenix_kit_organization_invitations
            (email, kind, status, token, expires_at, organization_uuid, relationship_type_uuid, inserted_at, updated_at)
          VALUES ($1, $2, 'pending', $3, now() + interval '1 day', $4, $5, now(), now())
          """,
          [
            "#{System.unique_integer([:positive])}@example.com",
            kind,
            :crypto.strong_rand_bytes(8),
            org,
            type
          ]
        )
      end

      manager_type = Ecto.UUID.dump!(RelationshipType.manager_uuid())

      insert.("manager", manager_type)
      insert.("member", nil)

      for {kind, type} <- [{"manager", nil}, {"member", manager_type}] do
        assert_raise Postgrex.Error, ~r/phoenix_kit_org_invitations_type_check/, fn ->
          Repo.transaction(fn -> insert.(kind, type) end)
        end
      end
    end
  end

  describe "the manifest" do
    defp declared_by_v229 do
      Enum.filter(ExpectedSchema.objects("public"), fn object ->
        Enum.any?(object.revisions, &(elem(&1, 0) == 229))
      end)
    end

    test "declares every new table, the changed tables' columns and the seed" do
      ids = MapSet.new(declared_by_v229(), & &1.id)

      for id <- [
            "table:phoenix_kit_relationship_types",
            "table:phoenix_kit_organization_manager_roles",
            "column:phoenix_kit_organization_managers.relationship_type_uuid",
            "column:phoenix_kit_organization_managers.all_roles",
            "column:phoenix_kit_organization_invitations.role_uuids",
            "column:phoenix_kit_user_roles.data",
            "seed:phoenix_kit_relationship_types:manager",
            "seed:phoenix_kit_relationship_types:staff"
          ] do
        assert id in ids, id
      end
    end

    test "what it declares matches what the chain built" do
      snapshot = Probe.snapshot(Repo, "public")

      problems =
        for object <- declared_by_v229(),
            object.class != :seed,
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
