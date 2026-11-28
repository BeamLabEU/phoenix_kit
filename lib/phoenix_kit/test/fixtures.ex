defmodule PhoenixKit.Test.Fixtures do
  @moduledoc """
  Test fixtures and session helpers for host applications.

  > #### ExUnit only {: .warning}
  >
  > These compile into your production build because they live in `lib/`, but
  > they exist solely for tests and are not part of the runtime API. Nothing
  > here is a supported thing to call from application code.

  ## Why this ships

  Every host was writing the same four helpers, and the hand-rolled login was
  subtly wrong: it set `:user_token` but not `:live_socket_id`, so LiveView's
  disconnect-on-logout never fired and a session-invalidation test was the only
  thing that would ever have caught it. That is a worse outcome than
  duplication, and it is what a shipped helper fixes.

  ## What is deliberately NOT here

  No `ConnCase`, no `DataCase`, no `Ecto.Adapters.SQL.Sandbox` calls. Those are
  bound to *your* endpoint and *your* repo, and a copy compiled in the kit's
  context could not adapt to either. Sandbox ownership stays yours. Everything
  here is portable: the fixtures go through `Auth.register_user/1`, which uses
  the configured repo, and the session helpers only put keys into a conn.

  ## Confirmed vs unconfirmed — read the test, do not memorise a default

  `user_fixture/1` produces an **unconfirmed** user, honestly mirroring what
  `register_user/1` does. Confirmation flips authentication behaviour, so a
  fixture that silently confirmed would leave a reader of

      user = user_fixture()

  unable to tell why a redirect gate did or did not fire. Ask for
  `confirmed_user_fixture/1` when you mean confirmed.

  (`confirmed_at == nil` after registration is correct, not a defect being
  papered over: `registration_changeset/3` refuses to cast it, confirmation is
  its own transition, and the gate exists precisely to handle the
  registered-but-unconfirmed state — so tests have to be able to produce it.)

  ## Usage

      defmodule MyAppWeb.AdminTest do
        use MyAppWeb.ConnCase
        import PhoenixKit.Test.Fixtures

        test "an admin reaches the dashboard", %{conn: conn} do
          %{conn: conn} = register_and_log_in_user(%{conn: conn})
          assert conn |> get(~p"/phoenix_kit/admin") |> html_response(200)
        end
      end
  """

  import Plug.Conn, only: [put_session: 3]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions

  @doc """
  A registered, **unconfirmed** user.

  Pass any `register_user/1` attributes to override; `email` and `password` are
  filled in with unique valid values when omitted.
  """
  @spec user_fixture(map()) :: Auth.User.t()
  def user_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.put_new("email", unique_user_email())
      |> Map.put_new("password", valid_user_password())

    # `nil` for the IP: `register_user/2` rate-limits per email AND per IP, and
    # the test adapter reports ONE peer for every conn — so passing a real IP
    # would put every fixture in the same bucket and fail the eleventh one under
    # `async: true`. A nil IP skips the IP-keyed half; the per-email half is
    # naturally distinct because the emails are.
    #
    # `first_owner: :allow`: as before, the first user of an empty database
    # becomes the Owner (the setup-token rule is for public sign-up, see
    # `PhoenixKit.Users.Setup`).
    {:ok, user} = Auth.register_user(attrs, nil, first_owner: :allow)
    user
  end

  @doc "A registered user whose email is confirmed."
  @spec confirmed_user_fixture(map()) :: Auth.User.t()
  def confirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} = attrs |> user_fixture() |> Auth.admin_confirm_user()
    user
  end

  @doc """
  A confirmed user, logged in on the given conn. The 90% case.

  Returns the context map with `:user` and an updated `:conn`, so it composes as
  an ExUnit `setup`:

      setup :register_and_log_in_user
  """
  @spec register_and_log_in_user(map()) :: map()
  def register_and_log_in_user(%{conn: conn} = context) do
    user = confirmed_user_fixture(Map.get(context, :user_attrs, %{}))
    %{context | conn: log_in_user(conn, user)} |> Map.put(:user, user)
  end

  @doc """
  Puts `user`'s session token into `conn`.

  Sets **both** `:user_token` and `:live_socket_id`. The second one is the
  reason this helper exists: without it `PhoenixKitWeb.Endpoint.broadcast` has
  no topic to reach the socket on, so logging out never disconnects the
  LiveView — and nothing but a session-invalidation test would reveal it.

  Takes a plain `build_conn()` conn: when the conn has no session yet it
  starts a test session (`Plug.Test.init_test_session/2`) first. A session
  already on the conn (from your own `init_test_session/2`) is kept, and the
  two keys are added to it.
  """
  @spec log_in_user(Plug.Conn.t(), Auth.User.t()) :: Plug.Conn.t()
  def log_in_user(conn, user) do
    token = Auth.generate_user_session_token(user)

    conn
    |> ensure_test_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, Sessions.live_socket_id(token))
  end

  # A conn straight from `build_conn()` has no session, and `put_session/3`
  # raises "session not fetched" on it. `init_test_session/2` with nothing to
  # add starts an empty one, or fetches one a session plug has set up.
  defp ensure_test_session(%Plug.Conn{private: %{plug_session: _}} = conn), do: conn
  defp ensure_test_session(conn), do: Plug.Test.init_test_session(conn, %{})

  @doc """
  A real `%Scope{}` for `user`, with roles and permissions loaded.

  For testing something that takes a scope directly, without a conn.
  """
  @spec scope_for(Auth.User.t() | nil) :: Scope.t()
  def scope_for(user), do: Scope.for_user(user)

  @doc "A confirmed user holding the Admin role."
  @spec admin_fixture(map()) :: Auth.User.t()
  def admin_fixture(attrs \\ %{}) do
    user = confirmed_user_fixture(attrs)
    {:ok, _} = Roles.promote_to_admin(user)
    # Matched, not just returned: a nil here would surface much later as
    # `nil.uuid` somewhere unrelated.
    %{uuid: _} = Auth.get_user(user.uuid)
  end

  @doc "An email address no other fixture in this run will use."
  @spec unique_user_email() :: String.t()
  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"

  @doc "A password that satisfies the registration changeset."
  @spec valid_user_password() :: String.t()
  def valid_user_password, do: "ValidPassword123!"

  # `register_user/1` casts string keys; accepting atom keys and converting is
  # kinder than making every caller remember which it wants.
  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
