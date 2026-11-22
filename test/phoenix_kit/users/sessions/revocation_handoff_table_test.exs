defmodule PhoenixKit.Users.Sessions.RevocationHandoffTableTest do
  @moduledoc """
  A host that runs this code before migration V236 has no `phoenix_kit_handoff_tokens` table. Every
  deletion of session tokens also deletes the account's handoff rows, in the same transaction, so a
  missing table must not abort it: the session has to end whatever the migration state.

  `async: false`: the table is dropped inside the test's sandbox transaction (rolled back at the
  end), which locks it and its account table against any concurrent test.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Handoff
  alias PhoenixKit.Migrations.Postgres.V236
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken

  defp drop_handoff_table, do: Enum.each(V236.down_statements("public"), &Repo.query!/1)

  defp session_rows(user),
    do: Repo.all(UserToken.by_user_and_contexts_query(user, ["session"]))

  setup do
    user = KeyTestSupport.register_user!()
    {:ok, user: user}
  end

  test "delete_user_session_token/1 ends the session with the table missing", %{user: user} do
    token = Auth.generate_user_session_token(user)
    other = Auth.generate_user_session_token(user)
    drop_handoff_table()

    assert :ok = Auth.delete_user_session_token(token)

    assert [%{token: remaining}] = session_rows(user)
    assert remaining == other
  end

  test "delete_all_user_session_tokens/1 ends every session with the table missing", %{user: user} do
    for _ <- 1..3, do: Auth.generate_user_session_token(user)
    assert length(session_rows(user)) == 3
    drop_handoff_table()

    assert :ok = Auth.delete_all_user_session_tokens(user)

    assert session_rows(user) == []
  end

  test "the enclosing transaction is still usable afterwards", %{user: user} do
    token = Auth.generate_user_session_token(user)
    drop_handoff_table()

    # A plain rescue would leave this transaction aborted ("current transaction is aborted"):
    # the query after the deletion is the proof it was not.
    assert :ok = Auth.delete_user_session_token(token)
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end

  test "revoke_for_users/1 answers 0 for a missing table and still deletes with the table there",
       %{user: user} do
    assert {:ok, _token} =
             Handoff.mint(%{
               target_host: "shop-de.test",
               redirect_path: "/",
               browser_nonce_hash: :crypto.hash(:sha256, "n"),
               user_uuid: user.uuid
             })

    assert Handoff.revoke_for_users([user.uuid]) == 1

    drop_handoff_table()
    assert Handoff.revoke_for_users([user.uuid]) == 0
  end
end
