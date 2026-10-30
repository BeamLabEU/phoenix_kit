defmodule PhoenixKit.Users.OrganizationEnterConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.ManagedOrganizations.Sessions, as: OrganizationSessions
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Users.Sessions.Revocation
  alias PhoenixKitWeb.Endpoint

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    Sandbox.mode(Repo, :auto)
    start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})
    PhoenixKit.Settings.update_setting("enable_organization_accounts", "true")
    {actor, admin} = F.admin_actor()
    person = F.person()
    other = F.person()
    org = F.organization()
    beta = F.organization()

    for organization <- [org, beta],
        manager <- [person, other],
        do: F.manager(organization, manager)

    {token, root} = F.session(person)
    ids = Enum.map([admin, person, other, org, beta], & &1.uuid)

    on_exit(fn ->
      if supervisor = Process.whereis(PhoenixKit.TaskSupervisor) do
        Enum.each(
          Task.Supervisor.children(supervisor),
          &Task.Supervisor.terminate_child(supervisor, &1)
        )
      end

      Sandbox.mode(Repo, :auto)
      Repo.delete_all(from(u in User, where: u.uuid in ^ids))
      PhoenixKit.Settings.update_setting("enable_organization_accounts", "false")
      Sandbox.mode(Repo, :manual)
    end)

    %{actor: actor, person: person, org: org, beta: beta, token: token, root: root}
  end

  for source <- [:root, :grant, :person, :organization] do
    test "#{source} revocation collects an earlier entry after its commit", s do
      {first, entered} = hold(fn -> OrganizationSessions.enter(s.token, s.org.uuid) end)
      Endpoint.subscribe(Sessions.live_socket_id(entered.token))
      second = blocked(fn -> revoke(unquote(source), s) end)
      release(first)
      assert {:ok, _} = Task.await(second, 5_000)
      refute Auth.get_user_by_session_token(entered.token)
      topic = Sessions.live_socket_id(entered.token)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 2_000
    end

    test "entry waiting behind #{source} revocation cannot mint a usable token", s do
      {first, _} = hold(fn -> revoke(unquote(source), s) end)
      second = blocked(fn -> OrganizationSessions.enter(s.token, s.org.uuid) end)
      release(first)
      assert {:error, :forbidden} = Task.await(second, 5_000)
      refute Repo.exists?(from(t in UserToken, where: t.acting_session_uuid == ^s.root.uuid))
    end
  end

  test "concurrent entries for different organizations serialize on the root and replace the old token",
       s do
    {first, entered} = hold(fn -> OrganizationSessions.enter(s.token, s.org.uuid) end)
    Endpoint.subscribe(Sessions.live_socket_id(entered.token))
    second = blocked(fn -> OrganizationSessions.enter(s.token, s.beta.uuid) end)
    release(first)
    assert {:ok, next} = Task.await(second, 5_000)
    assert next.user.uuid == s.beta.uuid
    refute Auth.get_user_by_session_token(entered.token)

    assert Repo.aggregate(
             from(t in UserToken, where: t.acting_session_uuid == ^s.root.uuid),
             :count
           ) == 1

    topic = Sessions.live_socket_id(entered.token)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  test "concurrent requests for the same organization reuse one token and one entry event", s do
    {first, entered} = hold(fn -> OrganizationSessions.enter(s.token, s.org.uuid) end)
    second = blocked(fn -> OrganizationSessions.enter(s.token, s.org.uuid) end)
    release(first)
    assert {:ok, next} = Task.await(second, 5_000)
    assert next.token == entered.token

    assert Repo.aggregate(
             from(e in Entry,
               where: e.action == "organization.entered" and e.resource_uuid == ^s.org.uuid
             ),
             :count
           ) == 1
  end

  test "rolling back replacement restores the previous token without disconnecting it", s do
    {:ok, entered} = OrganizationSessions.enter(s.token, s.org.uuid)
    Endpoint.subscribe(Sessions.live_socket_id(entered.token))

    assert {:error, :undone} =
             Revocation.transaction(fn ->
               assert {:ok, _} = OrganizationSessions.enter(s.token, s.beta.uuid)
               Repo.rollback(:undone)
             end)

    assert Auth.get_user_by_session_token(entered.token)
    topic = Sessions.live_socket_id(entered.token)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 30
  end

  defp revoke(:root, s) do
    :ok = Auth.delete_user_session_token(s.token)
    {:ok, :revoked}
  end

  defp revoke(:grant, s), do: OrganizationManagers.remove(s.actor, s.org.uuid, s.person.uuid)
  defp revoke(:person, s), do: Auth.update_user_status(s.person, %{is_active: false})
  defp revoke(:organization, s), do: Auth.update_user_status(s.org, %{is_active: false})

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

    assert_receive {:held, pid, {:ok, value}}, 5_000
    {{task, pid}, value}
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
    do: flunk("entry/revoker did not reach a PostgreSQL lock wait")

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
