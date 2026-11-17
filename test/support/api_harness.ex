defmodule PhoenixKit.Test.ApiHarness do
  @moduledoc """
  Helpers shared by the tests of the machine API: switch the API on, register
  the fake tool module, start the key cache, make users with exactly the
  permissions a test needs, issue real keys, and build requests that carry
  them.

  Users, owners, keys, client addresses and the key cache come from
  `PhoenixKit.API.KeyTestSupport`, the single source for them; the
  functions here delegate to it and add only what is specific to the machine
  API. Import this module, not `KeyTestSupport`, in a test file of this
  part, so no helper name is ambiguous.

  A key is created by its owner, as `Keys.create_key/3` demands (it refuses
  `:owner_not_allowed` when someone else, even the seeded Owner, creates a
  key for an ordinary user). So `user_with/1` always grants the `api`
  permission on top of the ones asked for, and `issue_key/3` creates the key
  with the owner's own scope.

  A settings write logs "Cache settings could not be invalidated: {:noproc"
  when the test runs no `:settings` cache, which is the normal case here (a
  test that needs the cache starts it itself). `switch/2` and `put_setting/2`
  keep that one warning out of the test output (`KeyTestSupport.write_setting/1`);
  any other line a write logs fails the test.

  Everything here goes through the real code (`PhoenixKit.API.Keys`,
  `PhoenixKit.Settings`, `PhoenixKit.ModuleRegistry`, the permission tables):
  nothing is mocked. Use it from a test case that has a database sandbox
  (`PhoenixKit.DataCase` or `PhoenixKitWeb.ConnCase`) and runs with
  `async: false`, because it registers a module in the global registry and
  starts the named key cache.
  """

  import ExUnit.Assertions, only: [assert: 1, flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Plug.Conn
  import Plug.Test, only: [conn: 2, conn: 3]

  alias PhoenixKit.API.Keys.Cache, as: KeyCache
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ApiTools

  @doc """
  Starts the key cache (`KeyTestSupport.start_key_cache!/0`, which also starts
  `PhoenixKit.Cache.Registry`), switches the API on and registers
  `PhoenixKit.Test.ApiTools`.

  Options: `admin: false` / `public: false` leave that switch off. The module
  is unregistered, and switched back on, when the test ends; the cache
  processes are stopped by ExUnit. A test that starts the registry itself
  must not: it is already running.

  The client policy of OAuth is saved as `any` (the install default is
  `approval`, under which a test client on an example host would wait for an
  approval); a test of another policy writes its own.
  """
  @spec setup_api(keyword()) :: :ok
  def setup_api(opts \\ []) do
    :ok = KeyTestSupport.start_key_cache!()
    :ok = ModuleRegistry.register(ApiTools)
    ApiTools.set_enabled(true)

    on_exit(fn ->
      ModuleRegistry.unregister(ApiTools)
      ApiTools.set_enabled(true)
    end)

    switch(:admin, Keyword.get(opts, :admin, true))
    switch(:public, Keyword.get(opts, :public, true))
    put_setting("api_oauth_client_policy", "any")
  end

  @doc "Sets the `api_admin_enabled` / `api_public_enabled` switch."
  @spec switch(:admin | :public, boolean()) :: :ok
  def switch(audience, on?) when audience in [:admin, :public] and is_boolean(on?) do
    KeyTestSupport.write_setting(fn ->
      Settings.update_boolean_setting("api_#{audience}_enabled", on?)
    end)
  end

  @doc """
  Sets a setting the way the admin page would, as a string.
  `KeyTestSupport.put_setting/2`.
  """
  @spec put_setting(String.t(), String.t() | integer()) :: :ok
  defdelegate put_setting(key, value), to: KeyTestSupport

  @doc """
  A user whose only extra role holds exactly `permissions` (module keys such
  as `"dashboard"`) **and the `api` permission**, so the user may own a key.
  Returns `{user, role}`; revoke from the role to take a permission away
  later. Delegates to `KeyTestSupport.user_with/1`.
  """
  @spec user_with([String.t()]) :: {PhoenixKit.Users.Auth.User.t(), PhoenixKit.Users.Role.t()}
  def user_with(permissions) when is_list(permissions),
    do: KeyTestSupport.user_with(Enum.uniq(["api" | permissions]))

  @doc "The suite's seeded Owner, who may delete users. `KeyTestSupport.owner_user/0`."
  @spec owner_user() :: PhoenixKit.Users.Auth.User.t()
  defdelegate owner_user(), to: KeyTestSupport

  @doc """
  Issues a key owned by `owner` with `scopes`, created BY `owner` with the
  owner's own scope (`KeyTestSupport.create_key!/3`). Extra `attrs` are merged
  into the key's attributes (`allowed_ips: [...]`, ...). Returns
  `{key, token}`.
  """
  @spec issue_key(PhoenixKit.Users.Auth.User.t(), [String.t()], map()) ::
          {PhoenixKit.API.Keys.Key.t(), String.t()}
  def issue_key(owner, scopes, attrs \\ %{}) do
    attrs = Map.merge(%{name: "harness key", scopes: scopes}, attrs)
    KeyTestSupport.create_key!(owner, KeyTestSupport.scope_of(owner), attrs)
  end

  @doc """
  A request `conn` for plug-level tests.

  Options: `:token` (sent as a bearer token), `:ip` (the peer, an address
  string; a fresh one by default, so tests never share a rate-limit bucket),
  `:headers`, `:body` (a map becomes `params` and `body_params`, as after
  `Plug.Parsers`; a binary stays the raw body).
  """
  @spec api_conn(atom(), String.t(), keyword()) :: Plug.Conn.t()
  def api_conn(method, path, opts \\ []) do
    conn =
      case Keyword.fetch(opts, :body) do
        {:ok, body} -> conn(method, path, body)
        :error -> conn(method, path)
      end

    conn = %{conn | remote_ip: opts |> Keyword.get_lazy(:ip, &unique_ip/0) |> peer()}
    conn = if token = opts[:token], do: bearer(conn, token), else: conn

    Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {name, value}, acc ->
      put_req_header(acc, name, value)
    end)
  end

  @doc """
  Gives a `Phoenix.ConnTest` conn a client address of its own, through
  `X-Forwarded-For` (believed because the test peer is loopback), so requests
  of different tests never share a rate-limit bucket.
  """
  @spec with_client_ip(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def with_client_ip(conn, ip \\ unique_ip()) when is_binary(ip),
    do: put_req_header(conn, "x-forwarded-for", ip)

  @doc "Adds the `Authorization: Bearer` header."
  @spec bearer(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  @doc """
  An IPv4 address string no other test has used in this run (the rate-limit
  counters are shared). `KeyTestSupport.unique_ip/0`: a string everywhere.
  """
  @spec unique_ip() :: String.t()
  defdelegate unique_ip(), to: KeyTestSupport

  # `conn.remote_ip` is a tuple; the helpers speak address strings.
  defp peer(ip) when is_binary(ip) do
    {:ok, tuple} = ip |> String.to_charlist() |> :inet.parse_address()
    tuple
  end

  @doc """
  Proves the row of the key with `prefix` is in the key cache: on a miss the
  loader runs and fails the test. A test about "the owner's rights are read
  afresh although the key is cached" would otherwise also pass with no cache
  at all.
  """
  @spec assert_row_cached(String.t()) :: :ok
  def assert_row_cached(prefix) do
    assert %{} = KeyCache.fetch(prefix, fn -> flunk("the key row is not cached") end)

    :ok
  end

  @doc "Decodes the JSON body of a sent response."
  @spec json(Plug.Conn.t()) :: term()
  def json(%Plug.Conn{resp_body: body}), do: JSON.decode!(body)
end
