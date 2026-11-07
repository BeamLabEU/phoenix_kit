defmodule PhoenixKit.Users.RelationshipTypesTest do
  use PhoenixKit.DataCase, async: true

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.RelationshipTypes

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: "staff_#{System.unique_integer([:positive])}",
        name: "Staff",
        inverse_name: "Staff members",
        from_kind: "person",
        to_kind: "organization",
        can_act: true,
        can_manage: false
      },
      overrides
    )
  end

  defp type!(overrides \\ %{}) do
    {:ok, type} = RelationshipTypes.create_type(attrs(overrides))
    type
  end

  defp error_on(changeset, field), do: Keyword.has_key?(changeset.errors, field)

  describe "reading" do
    test "the built-in type is there and active" do
      assert %RelationshipType{key: "manager", builtin: true, can_manage: true} =
               RelationshipTypes.manager_type()

      assert RelationshipTypes.get_type_by_key("manager").uuid ==
               RelationshipType.manager_uuid()

      assert RelationshipTypes.get_type(RelationshipType.manager_uuid())
      refute RelationshipTypes.get_type("not-a-uuid")
      refute RelationshipTypes.get_type(nil)
    end

    test "lists by status, in order" do
      first = type!()
      second = type!()
      {:ok, archived} = RelationshipTypes.archive_type(type!())

      RelationshipTypes.reorder([second.uuid, "not-a-uuid", first.uuid])

      active = RelationshipTypes.list_types(status: :active) |> Enum.map(& &1.uuid)

      assert Enum.find_index(active, &(&1 == second.uuid)) <
               Enum.find_index(active, &(&1 == first.uuid))

      refute archived.uuid in active
      assert archived.uuid in Enum.map(RelationshipTypes.list_types(status: :archived), & &1.uuid)
      assert archived.uuid in Enum.map(RelationshipTypes.list_types(), & &1.uuid)
    end
  end

  describe "create_type/2" do
    test "stores the names under the primary language and goes last" do
      before = type!()
      type = type!(%{name: "Agent", inverse_name: "Agents"})

      assert type.position > before.position
      assert RelationshipTypes.name(type) == "Agent"
      assert RelationshipTypes.inverse_name(type) == "Agents"
    end

    test "needs a name and a well-formed unique key" do
      assert {:error, cs} = RelationshipTypes.create_type(attrs(%{name: nil}))
      assert error_on(cs, :name)

      assert {:error, cs} = RelationshipTypes.create_type(attrs(%{key: "Not Valid"}))
      assert error_on(cs, :key)

      type = type!()
      assert {:error, cs} = RelationshipTypes.create_type(attrs(%{key: type.key}))
      assert error_on(cs, :key)
    end

    test "refuses a type that grants no access until those links exist" do
      assert {:error, cs} = RelationshipTypes.create_type(attrs(%{can_act: false}))
      assert error_on(cs, :can_act)
    end

    test "refuses acting for anything but a person acting for an organization" do
      for overrides <- [%{from_kind: "organization"}, %{to_kind: "person"}] do
        assert {:error, cs} = RelationshipTypes.create_type(attrs(overrides))
        assert error_on(cs, :can_act)
      end
    end

    test "builtin cannot be set from outside" do
      refute type!(%{builtin: true}).builtin
    end

    test "refuses a data map that would crash its readers" do
      for data <- ["a string", %{"_name" => 1}, %{"_primary_language" => "en", "en" => "x"}] do
        assert {:error, cs} = RelationshipTypes.create_type(attrs(%{data: data}))
        assert error_on(cs, :data)
      end
    end
  end

  describe "update_type/3" do
    test "changes names, order and status" do
      type = type!()

      assert {:ok, type} = RelationshipTypes.update_type(type, %{name: "Renamed", position: 7})
      assert RelationshipTypes.name(type) == "Renamed"
      assert type.position == 7
    end

    test "cannot change the key or a flag, whatever the params say" do
      type = type!()

      assert {:ok, updated} =
               RelationshipTypes.update_type(type, %{
                 "key" => "other",
                 "can_manage" => true,
                 "can_act" => false,
                 "from_kind" => "organization",
                 "to_kind" => "person",
                 "builtin" => true
               })

      assert Map.take(updated, [:key, :can_manage, :can_act, :from_kind, :to_kind, :builtin]) ==
               Map.take(type, [:key, :can_manage, :can_act, :from_kind, :to_kind, :builtin])
    end

    test "the built-in type keeps its name optional and can be relabelled" do
      manager = RelationshipTypes.manager_type()
      assert RelationshipTypes.name(manager, "en") == "Manager"

      assert {:ok, renamed} = RelationshipTypes.update_type(manager, %{name: "Owner of record"})
      assert RelationshipTypes.name(renamed) == "Owner of record"
    end
  end

  describe "the key" do
    test "comes from the name unless given" do
      name = "Sales Rep #{System.unique_integer([:positive])}"
      {:ok, type} = RelationshipTypes.create_type(attrs(%{key: nil, name: name}))
      assert type.key =~ ~r/^sales_rep_\d+$/
    end

    test "must be given when the name has no Latin letters" do
      assert {:error, cs} = RelationshipTypes.create_type(attrs(%{key: "", name: "Работник"}))
      assert error_on(cs, :key)
    end

    test "key_from/1 keeps to letters, digits and _" do
      assert RelationshipType.key_from("  Über Agent! 2 ") == "uber_agent_2"
      assert RelationshipType.key_from("123 go") == "go"
      assert RelationshipType.key_from("Работник") == ""
    end
  end

  test "link_counts/0 counts links by type" do
    type = type!()
    s = Fixtures.acting_session()

    Repo.update_all(from(m in OrganizationManager, where: m.uuid == ^s.manager.uuid),
      set: [relationship_type_uuid: type.uuid]
    )

    assert RelationshipTypes.link_counts()[type.uuid] == 1
  end

  describe "archive and delete" do
    test "archive stops nothing that exists, and restore brings the type back" do
      assert {:ok, %{status: "archived"} = type} = RelationshipTypes.archive_type(type!())
      assert {:ok, %{status: "active"}} = RelationshipTypes.restore_type(type)
    end

    test "manager cannot be archived or deleted" do
      manager = RelationshipTypes.manager_type()

      assert {:error, cs} = RelationshipTypes.archive_type(manager)
      assert error_on(cs, :status)
      assert {:error, :builtin} = RelationshipTypes.delete_type(manager)
    end

    test "staff can be archived by a site with no use for it, but not deleted" do
      staff = RelationshipTypes.get_type_by_key("staff")

      assert {:ok, %{status: "archived"}} = RelationshipTypes.archive_type(staff)
      assert {:error, :builtin} = RelationshipTypes.delete_type(staff)
    end

    test "an unused type is deleted" do
      type = type!()

      assert {:ok, _} = RelationshipTypes.delete_type(type)
      refute RelationshipTypes.get_type(type.uuid)
      assert {:error, :not_found} = RelationshipTypes.delete_type(type)
    end

    test "a type with a link cannot be deleted, only archived" do
      type = type!()
      s = Fixtures.acting_session()

      Repo.update_all(from(m in OrganizationManager, where: m.uuid == ^s.manager.uuid),
        set: [relationship_type_uuid: type.uuid]
      )

      assert RelationshipTypes.in_use?(type)
      assert {:error, :in_use} = RelationshipTypes.delete_type(type)
      assert {:ok, %{status: "archived"}} = RelationshipTypes.archive_type(type)
    end

    test "a type with an invitation cannot be deleted" do
      type = type!()
      organization = Fixtures.organization()

      Repo.insert!(%OrganizationInvitation{
        email: "invited@example.com",
        kind: :manager,
        token: :crypto.strong_rand_bytes(32),
        expires_at: DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second),
        organization_uuid: organization.uuid,
        relationship_type_uuid: type.uuid
      })

      assert {:error, :in_use} = RelationshipTypes.delete_type(type)
    end
  end

  describe "ensure/3" do
    @fixed [from_kind: "person", to_kind: "organization", can_act: true, can_manage: false]

    defp key, do: "ensured_#{System.unique_integer([:positive])}"

    test "creates a type with its translations" do
      key = key()

      assert {:ok, type} =
               RelationshipTypes.ensure(
                 key,
                 @fixed ++
                   [
                     names: %{"en" => "Employee", "de" => "Mitarbeiter"},
                     inverse_names: %{"en" => "Employees"}
                   ]
               )

      assert RelationshipTypes.name(type, "en") == "Employee"
      assert RelationshipTypes.name(type, "de") == "Mitarbeiter"
      assert RelationshipTypes.inverse_name(type, "en") == "Employees"
    end

    test "keeps what an admin edited" do
      key = key()
      {:ok, type} = RelationshipTypes.ensure(key, @fixed ++ [names: "Before"])
      {:ok, _} = RelationshipTypes.update_type(type, %{name: "After"})
      {:ok, _} = RelationshipTypes.archive_type(RelationshipTypes.get_type(type.uuid))

      assert {:ok, again} = RelationshipTypes.ensure(key, @fixed ++ [names: "Before"])
      assert again.uuid == type.uuid
      assert again.status == "archived"
      assert RelationshipTypes.name(again) == "After"
    end

    test "answers a conflict when the flags asked for differ from the stored ones" do
      key = key()
      {:ok, _} = RelationshipTypes.ensure(key, @fixed ++ [names: "Staff"])

      assert {:error, :type_conflict} =
               RelationshipTypes.ensure(key, Keyword.put(@fixed, :can_manage, true))

      assert {:ok, _} = RelationshipTypes.ensure("manager", can_manage: true)
      assert {:error, :type_conflict} = RelationshipTypes.ensure("manager", can_manage: false)
    end
  end

  describe "display" do
    test "reads the language, then the primary language, then the key" do
      type =
        type!(%{
          name: nil,
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Client of", "_inverse_name" => "Clients"},
            "de" => %{"_name" => "Kunde von"}
          }
        })

      assert RelationshipTypes.name(type, "de") == "Kunde von"
      assert RelationshipTypes.name(type, "fr") == "Client of"
      assert RelationshipTypes.inverse_name(type, "de") == "Clients"
      assert RelationshipTypes.name(%{type | data: %{}}, "de") == type.key
      assert RelationshipTypes.inverse_name(%{type | data: %{}}, "de") == type.key
    end
  end

  test "changes are logged with the actor" do
    actor = Fixtures.person()
    {:ok, type} = RelationshipTypes.create_type(attrs(), actor_uuid: actor.uuid)

    assert [%{actor_uuid: uuid, metadata: %{"key" => key}}] =
             Repo.all(
               from(e in Entry,
                 where: e.action == "relationship_type.created" and e.resource_uuid == ^type.uuid
               )
             )

    assert {uuid, key} == {actor.uuid, type.key}
  end
end
