defmodule PhoenixKitWeb.ConnCase do
  @moduledoc """
  This module defines the setup for tests requiring
  setting up a connection and LiveView support.

  For DB-backed tests (integration) set `use PhoenixKitWeb.ConnCase, async: true`.
  For pure conn tests without a DB, omit async or tag as needed.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      # The default endpoint for testing
      @endpoint PhoenixKitWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitWeb.ConnCase

      alias PhoenixKit.Test.Repo
      alias PhoenixKit.Users.Auth, as: AuthCtx
      alias PhoenixKit.Users.Roles

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Test.Repo, as: TestRepo
  alias PhoenixKit.Users.Auth, as: AuthCtx
  alias PhoenixKit.Users.Roles

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # The endpoint is started once for the suite in `test/test_helper.exs`.
    # Don't `start_supervised` it here — that ties the endpoint to a
    # single test pid and kills it for concurrent async tests.

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # ---------------------------------------------------------------------------
  # Auth helpers
  # ---------------------------------------------------------------------------

  @doc """
  Creates and confirms an admin user, returns {user, token}.
  """
  def create_admin_user(email \\ nil) do
    email = email || "admin_#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      AuthCtx.register_user(%{
        email: email,
        password: "TestPassword123!"
      })

    {:ok, user} = AuthCtx.admin_confirm_user(user)
    {:ok, _user} = Roles.assign_role(user, "Admin")
    # Reload to pick up associations
    user = TestRepo.get!(PhoenixKit.Users.Auth.User, user.uuid)
    user = TestRepo.preload(user, :role_assignments)

    token = AuthCtx.generate_user_session_token(user)
    {user, token}
  end

  @doc """
  Puts a valid user session token into the conn for LiveView testing.
  """
  def log_in_user(conn, user) do
    token = AuthCtx.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(
      :live_socket_id,
      "phoenix_kit_sessions:#{Base.url_encode64(token)}"
    )
  end
end
