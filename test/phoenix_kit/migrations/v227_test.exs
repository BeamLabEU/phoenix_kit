defmodule PhoenixKit.Migrations.Postgres.V227Test do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Postgres.V227
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken

  test "the generated manifest matches the catalog, including the changed invitation index" do
    snapshot = Probe.snapshot(Repo, "public")

    objects =
      Enum.filter(ExpectedSchema.objects("public"), fn object ->
        Enum.any?(object.revisions, &(elem(&1, 0) == 227))
      end)

    assert length(objects) == 27

    for object <- objects do
      {_version, expected} = List.last(object.revisions)
      observed = Probe.lookup(snapshot, object.check)
      assert observed != nil, object.id
      result = Differ.compare(object.class, expected, observed)

      assert result == :match or Differ.deparse_text_only?(result),
             "#{object.id}: #{inspect(result)}"
    end
  end

  test "token foreign keys are indexed and cascade; provenance is paired and session-only" do
    s = Fixtures.acting_session()

    names =
      ~w(phoenix_kit_users_tokens_acting_session_uuid_index phoenix_kit_users_tokens_organization_manager_index)

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND indexname = ANY($1)",
               [names]
             )

    for attrs <- [
          %{acting_session_uuid: s.root.uuid},
          %{organization_manager_uuid: s.manager.uuid},
          %{
            acting_session_uuid: s.root.uuid,
            organization_manager_uuid: s.manager.uuid,
            context: "confirm"
          }
        ] do
      {_token, row} = UserToken.build_session_token(s.organization)

      changeset =
        row
        |> Ecto.Changeset.change(attrs)
        |> Ecto.Changeset.check_constraint(:acting_session_uuid,
          name: :phoenix_kit_users_tokens_acting_pair_check
        )

      assert {:error, changeset} = Repo.insert(changeset, mode: :savepoint)
      assert changeset.errors[:acting_session_uuid]
    end
  end

  test "managed policy is constrained to an organization that is not a service user" do
    for attrs <- [
          %{managed_by_members: true},
          %{managed_by_members: true, account_type: "organization", api_only: true}
        ] do
      changeset =
        %User{}
        |> Ecto.Changeset.change(
          Map.merge(
            %{email: "check-#{UUIDv7.generate()}@example.com", hashed_password: "unused"},
            attrs
          )
        )
        |> Ecto.Changeset.check_constraint(:managed_by_members,
          name: :phoenix_kit_users_managed_organization_check
        )

      assert {:error, changeset} = Repo.insert(changeset, mode: :savepoint)
      assert changeset.errors[:managed_by_members]
    end
  end

  test "up is rerunnable and down/up restores the same schema" do
    Enum.each(V227.up_statements("public"), &Repo.query!/1)
    before = Probe.snapshot(Repo, "public")
    Enum.each(V227.down_statements("public"), &Repo.query!/1)
    Enum.each(V227.up_statements("public"), &Repo.query!/1)
    after_snapshot = Probe.snapshot(Repo, "public")
    # DROP/ADD changes physical column ordinals; repair compares logical shape.
    normalize = fn snapshot ->
      Map.update!(snapshot, :columns, fn columns ->
        Map.new(columns, fn {key, shape} -> {key, Map.delete(shape, :pos)} end)
      end)
    end

    assert normalize.(before) == normalize.(after_snapshot)
  end

  test "up does not depend on the connection search_path" do
    Repo.query!("SET LOCAL search_path TO ''")

    try do
      Enum.each(V227.up_statements("public"), &Repo.query!/1)
    after
      Repo.query!("RESET search_path")
    end
  end
end
