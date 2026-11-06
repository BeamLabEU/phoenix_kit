defmodule PhoenixKit.Integration.Integrations.TelegramLinkLockOrderTest do
  @moduledoc """
  Linking a chat against a credential change in flight, under real concurrency: separate
  database sessions, real commits, no sandbox.

  A password change or an external confirmation holds the user's row and then drops the
  link, which deletes the link tokens: users, then tokens. A link taking the same two rows
  the other way round (spend the token, then write the user) deadlocks with it, and
  Postgres kills one of the two: a 500 for the person changing their password.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  @moduletag :integration

  @chat 7_301

  setup do
    Sandbox.mode(Repo, :auto)

    {:ok, user} =
      Auth.register_user(%{
        email: "lock_order_#{System.unique_integer([:positive])}@example.com",
        password: "TestPassword123!"
      })

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      # Real commits, so nothing rolls back. The tokens go with the user; its activity does
      # not (the table has no foreign key to users), and a row left behind here makes the
      # doctor's destructive tests fail on every later run against this database.
      Repo.delete_all(
        from(e in Entry, where: e.actor_uuid == ^user.uuid or e.target_uuid == ^user.uuid)
      )

      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{user: user, connection: UUIDv7.generate()}
  end

  defp start_update(token) do
    %{
      "update_id" => 1,
      "message" => %{
        "chat" => %{"id" => @chat, "type" => "private"},
        "text" => "/start " <> token
      }
    }
  end

  # A task's raise comes back as a value: a deadlock must fail the assertion, not the link
  # between the task and the test.
  defp outcome(fun) do
    fun.()
  rescue
    error -> {:raised, error}
  end

  defp blocked_sessions do
    Repo.one(
      from(a in fragment("pg_stat_activity"),
        where: fragment("?.datname = current_database()", a),
        where: fragment("?.wait_event_type = 'Lock'", a),
        select: count()
      )
    )
  end

  defp await_blocked(tries \\ 200)

  defp await_blocked(0), do: flunk("the link never reached the row the holder has locked")

  defp await_blocked(tries) do
    if blocked_sessions() >= 1 do
      :ok
    else
      Process.sleep(10)
      await_blocked(tries - 1)
    end
  end

  test "a link in flight does not deadlock with a drop inside a credential change", %{
    user: user,
    connection: connection
  } do
    {:ok, token} = Linking.create_token(user, connection)
    parent = self()

    # `password_update_multi/2` as far as its drop: the row locked, then `drop_links/2`.
    credential_change =
      Task.async(fn ->
        outcome(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(u in User, where: u.uuid == ^user.uuid, lock: "FOR NO KEY UPDATE"))
            send(parent, :row_held)
            receive do: (:drop -> Linking.drop_links(user.uuid))
          end)
        end)
      end)

    assert_receive :row_held, 5_000

    log =
      capture_log(fn ->
        link =
          Task.async(fn ->
            outcome(fn -> Linking.handle_updates(connection, [start_update(token)]) end)
          end)

        await_blocked()
        send(credential_change.pid, :drop)

        assert Task.await(credential_change, 10_000) == {:ok, :ok}
        assert Task.await(link, 10_000) == {:ok, %{linked: 0}}
      end)

    refute log =~ "deadlock"
    assert Linking.linked_user(connection, @chat) == nil
    assert Linking.consume_token(token, connection) == :error
  end

  test "a link still lands when no credential change is in the way", %{
    user: user,
    connection: connection
  } do
    {:ok, token} = Linking.create_token(user, connection)

    capture_log(fn ->
      assert Linking.handle_updates(connection, [start_update(token)]) == {:ok, %{linked: 1}}
    end)

    assert Linking.linked_user(connection, @chat).uuid == user.uuid
  end
end
