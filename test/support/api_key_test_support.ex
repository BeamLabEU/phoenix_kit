defmodule PhoenixKit.API.KeyTestSupport do
  @moduledoc """
  Fixtures shared by the API key, service user and (later) executor tests.

  Scopes the fake module declares, and the core permission each needs:

  | Scope | Permission |
  |---|---|
  | `apikeytest.things:read` | `media` |
  | `apikeytest.things:write` | `media.manage` |
  | `apikeytest.jobs:run` | `jobs.manage` |
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Ecto.Changeset
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.KeyTestSupport.FakeModule
  alias PhoenixKit.API.ServiceUsers
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  @read "apikeytest.things:read"
  @write "apikeytest.things:write"
  @run "apikeytest.jobs:run"

  @doc "The scope names the fake module declares."
  def read_scope, do: @read
  def write_scope, do: @write
  def run_scope, do: @run
  def all_scopes, do: [@read, @write, @run]

  @doc "Registers the fake module for the current test and unregisters it afterwards."
  def register_fake_module! do
    ModuleRegistry.register(FakeModule)
    on_exit(fn -> ModuleRegistry.unregister(FakeModule) end)
    :ok
  end

  @doc """
  Starts `PhoenixKit.Cache.Registry` for the current test, so that a settings
  write without a `:settings` cache logs the one expected warning
  (`write_setting/1`) instead of "unknown registry". Needs `async: false`:
  the registry is named.
  """
  def start_cache_registry!, do: start_supervised!({PhoenixKit.Cache.Registry, []}) && :ok

  @doc """
  Starts the key row cache (`:api_keys`) and its invalidation listener for the
  current test (and the registry, `start_cache_registry!/0`). Needs
  `async: false`: the cache and the registry are named.
  """
  def start_key_cache! do
    start_cache_registry!()
    start_supervised!({PhoenixKit.Cache, name: :api_keys, ttl: :timer.seconds(60)})
    start_supervised!(PhoenixKit.API.Keys.Cache)
    :ok
  end

  @doc "The committed seed Owner of the test database."
  def owner_user, do: Auth.get_user_by_email("seed-owner@phoenixkit.test")

  @doc "A scope that ignores the role switcher, as the API computes it."
  def scope_of(%User{} = user), do: Scope.for_user(user, narrow: false)

  @doc """
  A user holding one new custom role that grants `permissions` **and `api`**, so
  the user can own and create keys.

  Returns `{user, role}`.
  """
  def user_with(permissions) do
    assign_new_role(["api" | permissions] |> Enum.uniq())
  end

  @doc """
  Like `user_with/1` but the role grants exactly `permissions`, so without `api`
  unless the list names it. For the tests that need a user the API refuses.
  """
  def user_without_api(permissions), do: assign_new_role(permissions)

  defp assign_new_role(permissions) do
    {role, _} = role_with(permissions)
    user = register_user!()
    {:ok, _} = Roles.assign_role(user, role.name)
    {user, role}
  end

  @doc "A new custom role granting exactly `permissions`. Returns `{role, permissions}`."
  def role_with(permissions) do
    {:ok, role} = Roles.create_role(%{name: "ApiTest#{System.unique_integer([:positive])}"})
    for key <- permissions, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    {role, permissions}
  end

  @doc """
  A user holding the `api` permission and `permissions`, with their scope.

  Returns `{user, role, scope}`.
  """
  def api_holder(permissions \\ ["media"]) do
    {user, role} = user_with(permissions)
    {user, role, scope_of(user)}
  end

  @doc """
  Creates a key through `Keys.create_key/3` and returns `{key, token}`.

  Defaults: a unique name and the read scope.
  """
  def create_key!(owner, creator_scope, attrs \\ %{}) do
    defaults = %{name: "Key #{System.unique_integer([:positive])}", scopes: [@read]}
    {:ok, key, token} = Keys.create_key(owner, creator_scope, Map.merge(defaults, attrs))
    {key, token}
  end

  @doc """
  Issues a key owned by `owner` and created BY `owner`
  (`Scope.for_user(owner, narrow: false)`), as the Settings page does when a
  person makes a key for themselves. Returns `{key, token}`.

  `owner` must hold `api` (every `user_with/1` user does; the seeded Owner does).
  The key is never created by the Owner for another ordinary user: `Keys` refuses
  that with `:owner_not_allowed`. Extra `attrs` win over the defaults
  (`name: "key"`, `scopes: scopes`).
  """
  def issue_key!(%User{} = owner, scopes, attrs \\ %{}) do
    create_key!(owner, scope_of(owner), Map.merge(%{name: "key", scopes: scopes}, attrs))
  end

  @doc """
  A service user (`api_only`) holding `role_names`, built through `ServiceUsers.create/2`
  by the seeded Owner, so the row has the shape production creates (username, creator,
  address, roles). The Owner may give any role but the Owner role. `creator_scope` is the
  scope of whoever creates it (the seeded Owner by default): a service user is the
  creator's to hand keys to.
  """
  def service_user_with(role_names, creator_scope \\ nil) do
    {:ok, user} =
      ServiceUsers.create(creator_scope || scope_of(owner_user()), %{roles: role_names})

    user
  end

  @doc "A confirmed user with the default role only, ready to use API keys."
  def register_user! do
    {:ok, user} =
      Auth.register_user(
        %{
          email: "apikeys_#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        },
        nil
      )

    user
    |> Changeset.change(confirmed_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Repo.update!()
  end

  # The lines a settings write logs when the test runs no `:settings` cache
  # (the registry runs, the cache does not), plus the same "cache absent"
  # warnings other processes can log into the capture window while the
  # registry is down between tests: "could not be invalidated" (the write's
  # own `invalidate_now/2` call), "unavailable" (a read whose registry is
  # gone) and "not started" (the write's own `invalidate/2` cast). All three
  # mean the same thing — no `:settings` cache in this test — so they are
  # expected; anything else still fails the test.
  defp expected_cache_warnings do
    [
      ~r/\A\d\d:\d\d:\d\d\.\d{3} \[warning\] Cache settings could not be invalidated: \{:noproc/,
      ~r/\A\d\d:\d\d:\d\d\.\d{3} \[warning\] Cache settings unavailable: /,
      ~r/\A\d\d:\d\d:\d\d\.\d{3} \[warning\] Cache settings not started/
    ]
  end

  @doc """
  Runs a settings write, `fun`, which must return `{:ok, _}`, and returns `:ok`.

  Most tests run no `:settings` cache, so every settings write logs a "cache
  absent" warning ("Cache settings could not be invalidated: {:noproc, ...}",
  or "unavailable" / "not started" when the registry itself is down). Those
  warnings are captured so they stay out of the test output. Any other line
  the write logs fails the test: nothing else is hidden.
  """
  def write_setting(fun) when is_function(fun, 0) do
    {{:ok, _setting}, log} = with_log(fun)

    case unexpected_lines(log) do
      [] ->
        :ok

      lines ->
        flunk(
          "a settings write logged more than the expected warning:\n" <> Enum.join(lines, "\n")
        )
    end
  end

  # One entry per log record: a record that wraps over several lines stays
  # in one piece.
  defp unexpected_lines(log) do
    warnings = expected_cache_warnings()

    ~r/\n(?=\d\d:\d\d:\d\d\.\d{3} \[)/
    |> Regex.split(String.trim(log))
    |> Enum.reject(&(&1 == "" or Enum.any?(warnings, fn re -> &1 =~ re end)))
  end

  @doc "Sets a setting the way the admin page would, as a string. See `write_setting/1`."
  def put_setting(key, value),
    do: write_setting(fn -> Settings.update_setting(key, to_string(value)) end)

  @doc "Sets an integer API setting such as `api_admin_rate_per_min`."
  def set_limit(setting, value) when is_integer(value), do: put_setting(setting, value)

  @doc "A token-like string no other test uses (client token hashes, key uuids)."
  def unique_token, do: "t#{System.unique_integer([:positive])}"

  @doc "The integer value of a response header from `PhoenixKit.API.RateLimit`."
  def header_value(headers, name) do
    headers |> List.keyfind(name, 0) |> elem(1) |> String.to_integer()
  end

  @doc """
  Lets a fixed-window rate limit test start with room left in the wall-clock
  window of `scale_ms` (a minute by default, an hour for the new rows). A test
  that counts several hits would otherwise see the counter reset when the window
  rolls over between two of them. Sleeps through the boundary when fewer than
  `min_left_ms` remain, so it costs a second or two once per window at most.
  The sleep is a deliberate exception to the no-`Process.sleep` rule: the window is
  aligned to the wall clock, so there is nothing to monitor or synchronise with.
  """
  def wait_for_window_room(scale_ms \\ 60_000, min_left_ms \\ 1_500) do
    left = scale_ms - rem(Hammer.ETS.now(), scale_ms)
    if left < min_left_ms, do: Process.sleep(left + 10)
    :ok
  end

  @doc "A private IPv4 address no other test uses (the rate limit counters are shared)."
  def unique_ip do
    n = System.unique_integer([:positive])
    "10.#{rem(n, 250) + 1}.#{rem(div(n, 250), 250) + 1}.#{rem(div(n, 62_500), 250) + 1}"
  end
end
