defmodule PhoenixKit.Users.Sessions.RevocationHandoffTableTest do
  @moduledoc """
  A host that runs this code before migration V236 has no `phoenix_kit_handoff_tokens` table. Every
  deletion of session tokens also deletes the account's handoff rows, in the same transaction, so a
  missing table must not abort it: the session has to end whatever the migration state.

  `async: false`: the table is dropped inside the test's sandbox transaction (rolled back at the
  end), which locks it and its account table against any concurrent test.
  """
  use PhoenixKit.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Handoff
  alias PhoenixKit.Handoff.Token
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
    session = user |> Auth.generate_user_session_token() |> Auth.get_session_token_record()

    assert {:ok, _token} =
             Handoff.mint(%{
               target_host: "shop-de.test",
               redirect_path: "/",
               browser_nonce_hash: :crypto.hash(:sha256, "n"),
               user_uuid: user.uuid,
               source_session_uuid: session.uuid
             })

    assert Handoff.revoke_for_users([user.uuid]) == 1

    drop_handoff_table()
    assert Handoff.revoke_for_users([user.uuid]) == 0
  end

  # The sandbox wraps every test in a transaction, which is the one situation `revoke_for_users/1`
  # (savepoint mode needs a transaction) used to work in. Its other caller is any code that
  # revokes with no transaction of its own: a real connection, no savepoint to take.
  describe "revoke_for_users/1 outside any transaction" do
    defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

    defp committed_user do
      email = "revoke-outside-#{System.unique_integer([:positive])}@example.com"

      {:ok, user} =
        Auth.register_user(%{"email" => email, "password" => "ValidPassword123!"})

      user
    end

    test "deletes the account's unused handoffs on a real connection" do
      unboxed(fn ->
        refute Repo.in_transaction?()
        user = committed_user()

        try do
          session = user |> Auth.generate_user_session_token() |> Auth.get_session_token_record()

          for _ <- 1..2 do
            assert {:ok, _token} =
                     Handoff.mint(%{
                       target_host: "shop-de.test",
                       redirect_path: "/",
                       browser_nonce_hash: :crypto.hash(:sha256, "n"),
                       user_uuid: user.uuid,
                       source_session_uuid: session.uuid
                     })
          end

          assert Handoff.revoke_for_users([user.uuid]) == 2
          assert Repo.aggregate(from(t in Token, where: t.user_uuid == ^user.uuid), :count) == 0
        after
          Repo.delete!(user)
        end
      end)
    end

    test "answers 0 when there is no handoff table, as a plain statement" do
      unboxed(fn ->
        refute Repo.in_transaction?()

        # No table to find: the session's search path knows nothing of the kit's tables.
        Repo.query!("SET search_path TO pg_catalog")

        try do
          assert Handoff.revoke_for_users([Ecto.UUID.generate()]) == 0
        after
          Repo.query!("RESET search_path")
        end

        assert %{rows: [[1]]} = Repo.query!("SELECT 1")
      end)
    end

    test "inside a transaction it still takes a savepoint: the table missing aborts nothing" do
      # The sandbox's own transaction is not the caller's (`in_transaction?/0` is false there);
      # `Repo.transaction/1` is the transaction `Revocation` runs the deletion in.
      assert {:ok, :usable} =
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()
                 drop_handoff_table()

                 assert Handoff.revoke_for_users([Ecto.UUID.generate()]) == 0
                 assert %{rows: [[1]]} = Repo.query!("SELECT 1")
                 :usable
               end)
    end
  end
end
