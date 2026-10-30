defmodule PhoenixKit.Users.ManagedOrganizationLifecycleConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthProvider
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.Roles

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    Sandbox.mode(Repo, :auto)
    start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})
    {actor, admin} = F.admin_actor()
    a = F.person()
    b = F.person()
    org = F.organization()
    other_org = F.organization()
    empty_org = F.organization()
    outsider = F.person()
    independent = F.person(%{account_type: "organization", organization_name: "Before"})
    for organization <- [org, other_org], person <- [a, b], do: F.manager(organization, person)
    ids = Enum.map([admin, a, b, org, other_org, empty_org, outsider, independent], & &1.uuid)

    on_exit(fn ->
      if supervisor = Process.whereis(PhoenixKit.TaskSupervisor) do
        Enum.each(
          Task.Supervisor.children(supervisor),
          &Task.Supervisor.terminate_child(supervisor, &1)
        )
      end

      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(u in User, where: u.uuid in ^ids))
      Sandbox.mode(Repo, :manual)
    end)

    %{
      actor: actor,
      admin: admin,
      a: a,
      b: b,
      org: org,
      other_org: other_org,
      empty_org: empty_org,
      outsider: outsider,
      independent: independent
    }
  end

  test "concurrent removals cannot both remove the last two managers", s do
    first = hold(fn -> OrganizationManagers.remove(s.actor, s.org.uuid, s.a.uuid) end)
    second = blocked(fn -> OrganizationManagers.remove(s.actor, s.org.uuid, s.b.uuid) end)
    release(first)
    assert {:error, :cannot_remove_last_active_manager} = Task.await(second, 5_000)
    assert Repo.get_by!(OrganizationManager, organization_uuid: s.org.uuid, user_uuid: s.b.uuid)
  end

  test "deactivation and removal share the organization's active-manager decision", s do
    first = hold(fn -> Auth.update_user_status(s.a, %{is_active: false}) end)
    second = blocked(fn -> OrganizationManagers.remove(s.actor, s.org.uuid, s.b.uuid) end)
    release(first)
    assert {:error, :cannot_remove_last_active_manager} = Task.await(second, 5_000)
    refute Repo.get!(User, s.a.uuid).is_active
    assert Repo.get!(User, s.b.uuid).is_active
  end

  test "two multi-organization deactivations lock in the same order and retain a manager", s do
    first = hold(fn -> Auth.update_user_status(s.a, %{is_active: false}) end)
    second = blocked(fn -> Auth.update_user_status(s.b, %{is_active: false}) end)
    release(first)
    assert {:error, :cannot_remove_last_active_manager} = Task.await(second, 5_000)
    assert Repo.get!(User, s.b.uuid).is_active
  end

  test "a committed type change prevents a waiting stale person from receiving a grant", s do
    first =
      hold(fn ->
        Auth.change_account_type(s.outsider, %{
          account_type: "organization",
          organization_name: "Changed"
        })
      end)

    second = blocked(fn -> OrganizationManagers.add(s.actor, s.org.uuid, s.outsider.uuid) end)
    release(first)
    assert {:error, :manager_must_be_active_person} = Task.await(second, 5_000)

    refute Repo.get_by(OrganizationManager,
             organization_uuid: s.org.uuid,
             user_uuid: s.outsider.uuid
           )
  end

  test "a committed grant prevents a waiting type change from leaving a stale grant", s do
    first = hold(fn -> OrganizationManagers.add(s.actor, s.org.uuid, s.outsider.uuid) end)

    second =
      blocked(fn ->
        Auth.change_account_type(s.outsider, %{
          account_type: "organization",
          organization_name: "Changed"
        })
      end)

    release(first)
    assert {:error, :organization_manager_must_be_person} = Task.await(second, 5_000)
    assert Repo.get!(User, s.outsider.uuid).account_type == "person"
  end

  test "UUID case variants cannot bypass the grant-topology lifecycle lock", s do
    first =
      hold(fn ->
        OrganizationManagers.add(s.actor, s.empty_org.uuid, String.upcase(s.outsider.uuid))
      end)

    second = blocked(fn -> Auth.update_user_status(s.outsider, %{is_active: false}) end)
    release(first)
    assert {:error, :cannot_remove_last_active_manager} = Task.await(second, 5_000)
    assert Repo.get!(User, s.outsider.uuid).is_active
  end

  test "conversion locks out a stale password form until it can see managed policy", s do
    first =
      hold(fn ->
        ManagedOrganizations.convert_to_managed(s.actor, s.independent.uuid, s.outsider.uuid)
      end)

    second =
      blocked(fn ->
        Auth.admin_update_user_password(s.independent, %{password: "AnotherPassword123!"})
      end)

    release(first)
    assert {:error, %Ecto.Changeset{}} = Task.await(second, 5_000)
    assert Repo.get!(User, s.independent.uuid).managed_by_members
  end

  test "conversion and a forbidden role assignment serialize on current user policy", s do
    first =
      hold(fn ->
        ManagedOrganizations.convert_to_managed(s.actor, s.independent.uuid, s.outsider.uuid)
      end)

    second = blocked(fn -> Roles.assign_role(s.independent, "Admin") end)
    release(first)
    assert {:error, :managed_organization_role_not_allowed} = Task.await(second, 5_000)
    refute Roles.user_has_role?(s.independent, "Admin")
  end

  test "a preceding staff assignment makes conversion refuse instead of dropping the role", s do
    first = hold(fn -> Roles.assign_role(s.independent, "Admin") end)

    second =
      blocked(fn ->
        ManagedOrganizations.convert_to_managed(s.actor, s.independent.uuid, s.outsider.uuid)
      end)

    release(first)
    assert {:error, :managed_organization_role_not_allowed} = Task.await(second, 5_000)
    refute Repo.get!(User, s.independent.uuid).managed_by_members
  end

  test "revoking the admin session wins over a waiting manager mutation", s do
    {token_uuid, _} = s.actor.current
    token = Repo.get!(UserToken, token_uuid).token

    first =
      hold(fn ->
        Auth.delete_user_session_token(token)
        {:ok, :revoked}
      end)

    second = blocked(fn -> OrganizationManagers.add(s.actor, s.org.uuid, s.outsider.uuid) end)
    release(first)
    assert {:error, :forbidden} = Task.await(second, 5_000)

    refute Repo.get_by(OrganizationManager,
             organization_uuid: s.org.uuid,
             user_uuid: s.outsider.uuid
           )
  end

  for writer <- [:oauth, :api_create, :api_rotate] do
    test "conversion drains a preceding #{writer} write after its real commit", s do
      mint = credential_writer(unquote(writer), s.independent)
      first = hold(mint)

      second =
        blocked(fn ->
          ManagedOrganizations.convert_to_managed(s.actor, s.independent.uuid, s.outsider.uuid)
        end)

      release(first)
      assert {:ok, _} = Task.await(second, 5_000)
      refute Repo.exists?(from(p in OAuthProvider, where: p.user_uuid == ^s.independent.uuid))

      refute Repo.exists?(
               from(k in Key, where: k.user_uuid == ^s.independent.uuid and is_nil(k.revoked_at))
             )
    end

    test "a waiting #{writer} write cannot escape conversion's credential drain", s do
      mint = credential_writer(unquote(writer), s.independent)

      first =
        hold(fn ->
          ManagedOrganizations.convert_to_managed(s.actor, s.independent.uuid, s.outsider.uuid)
        end)

      second = blocked(mint)
      release(first)
      assert {:error, reason} = Task.await(second, 5_000)
      assert reason in [:forbidden, :managed_organization]
      refute Repo.exists?(from(p in OAuthProvider, where: p.user_uuid == ^s.independent.uuid))

      refute Repo.exists?(
               from(k in Key, where: k.user_uuid == ^s.independent.uuid and is_nil(k.revoked_at))
             )
    end
  end

  defp credential_writer(:oauth, user) do
    fn ->
      OAuth.link_oauth_provider(user, %{
        provider: "google",
        provider_uid: UUIDv7.generate(),
        email: user.email
      })
    end
  end

  defp credential_writer(kind, user) do
    # The scope represents a request authorized before its org lost API
    # authority. Conversion must recheck the stored account policy, even when
    # the caller still has that older scope in memory.
    scope = %Scope{
      user: user,
      authenticated?: true,
      cached_roles: ["Owner"],
      cached_permissions: MapSet.new(["api"])
    }

    if kind == :api_create do
      fn ->
        case Keys.create_key(user, scope, %{name: "Concurrent", scopes: []}) do
          {:ok, key, _token} -> {:ok, key}
          error -> error
        end
      end
    else
      {:ok, key, _token} = Keys.create_key(user, scope, %{name: "Before", scopes: []})

      fn ->
        case Keys.rotate(key, 0, scope) do
          {:ok, rotated, _token} -> {:ok, rotated}
          error -> error
        end
      end
    end
  end

  defp hold(fun) do
    parent = self()

    task =
      task(fn ->
        Repo.transaction(fn ->
          result = fun.()
          send(parent, {:held, self(), result})

          receive do
            :commit -> result
          after
            10_000 -> Repo.rollback(:barrier_timeout)
          end
        end)
      end)

    assert_receive {:held, pid, {:ok, _}}, 5_000
    {task, pid}
  end

  defp blocked(fun) do
    parent = self()

    task =
      task(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, backend})
          fun.()
        end)
      end)

    assert_receive {:backend, backend}, 2_000
    assert_blocked(backend)
    task
  end

  defp release({task, pid}) do
    send(pid, :commit)
    assert {:ok, _} = Task.await(task, 5_000)
  end

  defp task(fun), do: Task.Supervisor.async_nolink(PhoenixKit.TaskSupervisor, fun)

  defp assert_blocked(backend, remaining \\ 200)
  defp assert_blocked(_backend, 0), do: flunk("mutation did not reach a PostgreSQL lock wait")

  defp assert_blocked(backend, remaining) do
    %{rows: rows} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend])

    if rows == [["Lock"]] do
      :ok
    else
      Process.sleep(10)
      assert_blocked(backend, remaining - 1)
    end
  end
end
