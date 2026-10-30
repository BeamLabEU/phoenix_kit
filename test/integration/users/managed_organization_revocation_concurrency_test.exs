defmodule PhoenixKit.Users.ManagedOrganizationRevocationConcurrencyTest do
  @moduledoc """
  Separate PostgreSQL connections, real commits and explicit lock barriers.
  The SQL sandbox cannot prove either FK lock ordering or post-commit delivery.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Users.Sessions.Revocation
  alias PhoenixKitWeb.Endpoint

  @moduletag :integration
  @moduletag timeout: 30_000

  setup do
    Sandbox.mode(Repo, :auto)
    start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})
    s = Fixtures.acting_session()
    watch(s.root_token)
    watch(s.token)

    on_exit(fn ->
      if supervisor = Process.whereis(PhoenixKit.TaskSupervisor) do
        Enum.each(
          Task.Supervisor.children(supervisor),
          &Task.Supervisor.terminate_child(supervisor, &1)
        )
      end

      Sandbox.mode(Repo, :auto)
      ids = [s.person.uuid, s.organization.uuid]
      Repo.delete_all(from(u in User, where: u.uuid in ^ids))
      Sandbox.mode(Repo, :manual)
    end)

    %{s: s}
  end

  defp watch(token), do: Endpoint.subscribe(Sessions.live_socket_id(token))

  defp closed(token) do
    topic = Sessions.live_socket_id(token)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 2_000
  end

  defp still_open(token) do
    topic = Sessions.live_socket_id(token)
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 50
  end

  defp observer do
    [pid] = Task.Supervisor.children(PhoenixKit.TaskSupervisor)
    {pid, Process.monitor(pid)}
  end

  defp await_observer({pid, ref}),
    do: assert_receive({:DOWN, ^ref, :process, ^pid, :normal}, 2_000)

  test "a host-owned transaction disconnects only after its real commit", %{s: s} do
    assert {:ok, observation} =
             Repo.transaction(fn ->
               assert :ok = Auth.delete_user_session_token(s.root_token)
               observation = observer()
               still_open(s.root_token)
               still_open(s.token)
               observation
             end)

    closed(s.root_token)
    closed(s.token)
    await_observer(observation)
  end

  test "a host rollback restores the tokens and stops its observer without disconnecting", %{s: s} do
    test_process = self()

    assert {:error, :undone} =
             Repo.transaction(fn ->
               Auth.delete_user_session_token(s.root_token)
               send(test_process, {:observation, observer()})
               still_open(s.token)
               Repo.rollback(:undone)
             end)

    assert_receive {:observation, observation}
    await_observer(observation)
    assert Auth.get_user_by_session_token(s.root_token)
    assert Auth.get_user_by_session_token(s.token)
    still_open(s.root_token)
    still_open(s.token)
  end

  test "a host-owned revoke works when the task supervisor cannot accept a child", %{s: s} do
    stop_supervised(PhoenixKit.TaskSupervisor)
    start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor, max_children: 0})

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Auth.delete_user_session_token(s.root_token)
               still_open(s.token)
               :ok
             end)

    closed(s.root_token)
    closed(s.token)
  end

  test "token collection and the post-commit absence check never log raw session tokens", %{s: s} do
    secret = String.duplicate("secret-session-", 4)
    s.root |> Ecto.Changeset.change(token: secret) |> Repo.update!()

    log =
      PhoenixKit.DataCase.capture_debug_log(fn ->
        Auth.delete_user_session_token(secret)
        Repo.query!("SELECT 1")
      end)

    assert log =~ "SELECT 1"
    refute log =~ secret
    refute log =~ inspect(s.token)
  end

  test "a failed host-owned credential rotation preserves both its password and sessions", %{s: s} do
    test_process = self()

    assert {:error, :undone} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Auth.reset_user_password(s.person, %{password: "DifferentPassword123!"})

               send(test_process, {:observation, observer()})
               Repo.rollback(:undone)
             end)

    assert_receive {:observation, observation}
    await_observer(observation)
    assert Repo.get!(User, s.person.uuid).hashed_password == s.person.hashed_password
    assert Auth.get_user_by_session_token(s.token)
    still_open(s.root_token)
    still_open(s.token)
  end

  for owner <- [:host, :revocation] do
    test "a rolled-back savepoint under a #{owner} transaction never disconnects restored tokens",
         %{s: s} do
      wrapper =
        if unquote(owner) == :host, do: &Repo.transaction/1, else: &Revocation.transaction/1

      assert {:ok, observation} =
               wrapper.(fn ->
                 Repo.query!("SAVEPOINT before_revoke")
                 Auth.delete_user_session_token(s.root_token)
                 observation = if unquote(owner) == :host, do: observer()
                 Repo.query!("ROLLBACK TO SAVEPOINT before_revoke")
                 observation
               end)

      if observation, do: await_observer(observation)
      assert Auth.get_user_by_session_token(s.token)
      still_open(s.root_token)
      still_open(s.token)
    end
  end

  for source <- [:session, :grant] do
    test "#{source} revoke waits for an earlier token insert, collects it and disconnects it", %{
      s: s
    } do
      test_process = self()
      {raw, row} = child(s)
      watch(raw)

      inserter =
        task(fn ->
          Repo.transaction(fn ->
            inserted = Repo.insert!(row, log: false)
            send(test_process, {:inserted, self(), inserted.uuid})

            receive do
              :commit -> inserted.uuid
            after
              10_000 -> Repo.rollback(:barrier_timeout)
            end
          end)
        end)

      assert_receive {:inserted, inserter_pid, child_uuid}, 2_000

      revoker =
        task(fn ->
          Repo.transaction(fn ->
            send(test_process, {:revoker_backend, backend_pid()})
            revoke(unquote(source), s)
          end)
        end)

      assert_receive {:revoker_backend, backend}, 2_000
      assert_blocked(backend)
      still_open(raw)
      send(inserter_pid, :commit)
      assert {:ok, ^child_uuid} = Task.await(inserter, 5_000)
      assert {:ok, _} = Task.await(revoker, 5_000)
      closed(raw)
      closed(s.token)
      assert Repo.get(UserToken, child_uuid) == nil
      if unquote(source) == :grant, do: still_open(s.root_token), else: closed(s.root_token)
    end

    test "#{source} revoke prevents a later token insert from escaping its disconnect collection",
         %{s: s} do
      test_process = self()

      revoker =
        task(fn ->
          Repo.transaction(fn ->
            revoke(unquote(source), s)
            send(test_process, {:deleted, self()})

            receive do
              :commit -> :ok
            after
              10_000 -> Repo.rollback(:barrier_timeout)
            end
          end)
        end)

      assert_receive {:deleted, revoker_pid}, 2_000
      {raw, row} = child(s)
      watch(raw)

      inserter =
        task(fn ->
          Repo.transaction(fn ->
            send(test_process, {:inserter_backend, backend_pid()})

            row
            |> Ecto.Changeset.change()
            |> Ecto.Changeset.foreign_key_constraint(:acting_session_uuid,
              name: :pk_tokens_acting_session_fkey
            )
            |> Ecto.Changeset.foreign_key_constraint(:organization_manager_uuid,
              name: :pk_tokens_organization_manager_fkey
            )
            |> Repo.insert(mode: :savepoint, log: false)
          end)
        end)

      assert_receive {:inserter_backend, backend}, 2_000
      assert_blocked(backend)
      still_open(s.token)
      send(revoker_pid, :commit)
      assert {:ok, :ok} = Task.await(revoker, 5_000)
      assert {:ok, {:error, %Ecto.Changeset{}}} = Task.await(inserter, 5_000)
      assert Auth.get_user_by_session_token(raw) == nil
      closed(s.token)
      if unquote(source) == :grant, do: still_open(s.root_token), else: closed(s.root_token)
    end
  end

  defp task(fun), do: Task.Supervisor.async_nolink(PhoenixKit.TaskSupervisor, fun)

  defp child(s) do
    {raw, row} = UserToken.build_session_token(s.organization)
    {raw, %{row | acting_session_uuid: s.root.uuid, organization_manager_uuid: s.manager.uuid}}
  end

  defp revoke(:session, s), do: Auth.delete_user_session_token(s.root_token)

  defp revoke(:grant, s),
    do:
      Revocation.delete_manager_grants(
        from(m in OrganizationManager, where: m.uuid == ^s.manager.uuid)
      )

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp assert_blocked(pid, remaining \\ 200)

  defp assert_blocked(_pid, 0),
    do: flunk("the other transaction never reached a PostgreSQL lock wait")

  defp assert_blocked(pid, remaining) do
    %{rows: rows} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid])

    if rows == [["Lock"]] do
      :ok
    else
      Process.sleep(10)
      assert_blocked(pid, remaining - 1)
    end
  end
end
