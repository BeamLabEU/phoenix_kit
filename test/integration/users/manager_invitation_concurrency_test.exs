defmodule PhoenixKit.Users.ManagerInvitationConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Referrals

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    Sandbox.mode(Repo, :auto)
    start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})
    s = F.acting_session()
    {admin_actor, admin} = F.admin_actor()
    person = F.person()

    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, person.email, F.acting_actor(s),
        kind: :manager
      )

    ids = Enum.map([s.person, s.organization, admin, person], & &1.uuid)

    on_exit(fn ->
      if supervisor = Process.whereis(PhoenixKit.TaskSupervisor),
        do:
          Enum.each(
            Task.Supervisor.children(supervisor),
            &Task.Supervisor.terminate_child(supervisor, &1)
          )

      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(u in User, where: u.uuid in ^ids))
      Sandbox.mode(Repo, :manual)
    end)

    %{org: s.organization, actor: admin_actor, person: person, invitation: invitation}
  end

  for source <- [:conversion, :deactivation, :cancellation, :decline] do
    test "acceptance waiting for #{source} cannot create a grant", s do
      first = hold(fn -> revoke(unquote(source), s) end)

      second =
        blocked(fn -> Invitations.accept_invitation_by_uuid(s.invitation.uuid, s.person) end)

      release(first)
      assert {:error, _} = Task.await(second, 5_000)

      refute Repo.get_by(OrganizationManager,
               organization_uuid: s.org.uuid,
               user_uuid: s.person.uuid
             )
    end
  end

  test "concurrent accept attempts produce one grant and one activity", s do
    first = hold(fn -> Invitations.accept_invitation_by_uuid(s.invitation.uuid, s.person) end)
    second = blocked(fn -> Invitations.accept_invitation_by_uuid(s.invitation.uuid, s.person) end)
    release(first)
    assert {:error, :not_pending} = Task.await(second, 5_000)

    assert Repo.get_by!(OrganizationManager,
             organization_uuid: s.org.uuid,
             user_uuid: s.person.uuid
           )

    assert Repo.aggregate(
             from(e in Entry,
               where: e.action == "organization.manager_added" and e.target_uuid == ^s.person.uuid
             ),
             :count
           ) == 1
  end

  test "conversion waits for an accepted grant and removes it before clearing managed policy",
       s do
    first = hold(fn -> Invitations.accept_invitation_by_uuid(s.invitation.uuid, s.person) end)
    second = blocked(fn -> revoke(:conversion, s) end)
    release(first)
    assert {:ok, _} = Task.await(second, 5_000)
    refute Repo.get!(User, s.org.uuid).managed_by_members

    refute Repo.get_by(OrganizationManager,
             organization_uuid: s.org.uuid,
             user_uuid: s.person.uuid
           )
  end

  test "rollback restores the pending invite and removes grant, admission and activity", s do
    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Invitations.accept_invitation_by_uuid(s.invitation.uuid, s.person)

               Repo.rollback(:cancelled)
             end)

    assert Repo.get!(OrganizationInvitation, s.invitation.uuid).status == :pending

    refute Repo.get_by(OrganizationManager,
             organization_uuid: s.org.uuid,
             user_uuid: s.person.uuid
           )

    refute Referrals.marked_satisfied?(Repo.get!(User, s.person.uuid))

    refute Repo.exists?(
             from(e in Entry,
               where: e.action == "organization.manager_added" and e.target_uuid == ^s.person.uuid
             )
           )
  end

  defp revoke(:conversion, s),
    do:
      ManagedOrganizations.convert_to_independent(s.actor, s.org.uuid, %{
        email: "converted-#{UUIDv7.generate()}@example.com",
        password: "NewPassword123!"
      })

  defp revoke(:deactivation, s), do: Auth.update_user_status(s.person, %{is_active: false})

  defp revoke(:cancellation, s),
    do: Invitations.cancel_invitation(s.actor, s.org.uuid, s.invitation.uuid)

  defp revoke(:decline, s),
    do: Invitations.decline_invitation_by_uuid(s.invitation.uuid, s.person)

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

  defp assert_blocked(_backend, 0),
    do: flunk("invitation transaction did not reach a PostgreSQL lock wait")

  defp assert_blocked(backend, remaining) do
    %{rows: rows} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend])

    if rows == [["Lock"]],
      do: :ok,
      else:
        (
          Process.sleep(10)
          assert_blocked(backend, remaining - 1)
        )
  end
end
