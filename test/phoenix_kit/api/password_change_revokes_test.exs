defmodule PhoenixKit.API.PasswordChangeRevokesTest do
  @moduledoc """
  `api_pw_change_revokes`: while it is on, a changed password ends the personal keys and the
  OAuth connections of the person, in the transaction of the change, on all four paths (the
  person's form, a reset, an administrator or the system, and the confirmation by an external
  proof); a first password is a change like any other; only personal keys and OAuth connections end:
  a key made under Keys and service users stays, whoever owns it (a service user's, or the person's own, which
  an administrator can make in their own name); a failure ends the change; the keys' cache is
  cleared again after the commit.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport, only: [client!: 0, seed_grant!: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Cache
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  @current "ValidPassword123!"
  @new "AnotherPassword456!"
  @attrs %{password: @new, password_confirmation: @new}

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, _role, scope} = api_holder(["media"])
    %{user: user, scope: scope}
  end

  defp switch(value) do
    write_setting(fn -> Settings.update_boolean_setting("api_pw_change_revokes", value) end)
  end

  defp personal!(scope, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "Agent #{System.unique_integer([:positive])}",
          scopes: [read_scope()],
          expires_at: DateTime.add(DateTime.utc_now(), 30 * 86_400, :second)
        },
        extra
      )

    {:ok, key, token} = Keys.create_personal_key(scope, attrs, impersonated: false)
    {key, token}
  end

  # What a person has: a personal key and its token, a connection, a key made under Keys and service users in
  # their own name (not personal) and a key of a service user they made (not theirs).
  defp holdings(user, scope) do
    {personal, token} = personal!(scope)
    seeded = seed_grant!(scope, [])
    {own_key, own_token} = issue_key!(user, [read_scope()])
    {service_role, _} = role_with(["media"])
    service_user = service_user_with([service_role.name], scope)
    {service, service_token} = create_key!(service_user, scope, %{name: "Robot"})

    %{
      personal: personal,
      token: token,
      grant: seeded.grant,
      hidden: seeded.key,
      access: seeded.access,
      own_key: own_key,
      own_token: own_token,
      service: service,
      service_token: service_token
    }
  end

  defp key(%Key{uuid: uuid}), do: Repo.get!(Key, uuid)
  defp grant(%Grant{uuid: uuid}), do: Repo.get!(Grant, uuid)
  defp hash_of(user), do: Repo.get!(User, user.uuid).hashed_password

  defp alive?(%Key{} = held), do: key(held).revoked_at == nil
  defp alive?(%Grant{} = held), do: grant(held).revoked_at == nil

  defp assert_everything_ended(held) do
    refute alive?(held.personal)
    refute alive?(held.grant)
    refute alive?(held.hidden)
    assert {:error, _} = Keys.verify(held.token, "127.0.0.1")
    assert alive?(held.own_key)
    assert {:ok, _} = Keys.verify(held.own_token, "127.0.0.1")
    assert alive?(held.service)
    assert {:ok, _} = Keys.verify(held.service_token, "127.0.0.1")

    assert Repo.aggregate(
             from(t in Token, where: t.grant_uuid == ^held.grant.uuid and is_nil(t.revoked_at)),
             :count
           ) == 0
  end

  defp assert_everything_alive(held) do
    assert alive?(held.personal)
    assert alive?(held.grant)
    assert alive?(held.hidden)
    assert {:ok, _} = Keys.verify(held.token, "127.0.0.1")
  end

  defp activity_count(user),
    do: Activity.count(action: "api.revoked_on_password_change", resource_uuid: user.uuid)

  describe "the setting" do
    test "is off unless it reads true" do
      refute Config.password_change_revokes?()
      switch(true)
      assert Config.password_change_revokes?()
      switch(false)
      refute Config.password_change_revokes?()
    end
  end

  describe "off" do
    test "a changed password leaves every key and connection alone", %{user: user, scope: scope} do
      held = holdings(user, scope)

      assert {:ok, _} = Auth.update_user_password(user, @current, @attrs)

      assert_everything_alive(held)
      assert activity_count(user) == 0
    end
  end

  describe "on, the person's own form" do
    setup do
      switch(true)
    end

    test "ends the personal keys and the connections, and not the keys made under Keys and service users",
         %{
           user: user,
           scope: scope
         } do
      held = holdings(user, scope)
      assert {:ok, _} = Keys.verify(held.token, "127.0.0.1")

      assert {:ok, _} = Auth.update_user_password(user, @current, @attrs)

      assert_everything_ended(held)
    end

    test "ends a personal key in the grace period of a rotation too", %{
      user: user,
      scope: scope
    } do
      {key, token} = personal!(scope)
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)
      Repo.update_all(from(k in Key, where: k.uuid == ^key.uuid), set: [revoked_at: later])
      assert {:ok, _} = Keys.verify(token, "127.0.0.1")

      assert {:ok, _} = Auth.update_user_password(user, @current, @attrs)

      assert DateTime.compare(key(key).revoked_at, DateTime.utc_now()) != :gt
      assert {:error, _} = Keys.verify(token, "127.0.0.1")
    end

    test "ends a connection that is not activated and one that waits for approval", %{
      user: user,
      scope: scope
    } do
      waiting = seed_grant!(scope, approved?: false)
      {:ok, plain, _hidden} = new_grant(scope)

      assert {:ok, _} = Auth.update_user_password(user, @current, @attrs)

      refute alive?(waiting.grant)
      refute alive?(plain)
    end

    test "touches nobody else's keys", %{user: user, scope: scope} do
      {_other, _role, other_scope} = api_holder(["media"])
      {other_key, other_token} = personal!(other_scope)
      other_grant = seed_grant!(other_scope, [])
      _mine = holdings(user, scope)

      assert {:ok, _} = Auth.update_user_password(user, @current, @attrs)

      assert alive?(other_key)
      assert {:ok, _} = Keys.verify(other_token, "127.0.0.1")
      assert alive?(other_grant.grant)
    end

    test "writes one entry with the numbers and the path", %{user: user, scope: scope} do
      _held = holdings(user, scope)

      assert {:ok, _} = Auth.update_user_password(user, @current, @attrs)

      assert [entry] = entries(user)

      assert entry.metadata["keys"] == 1
      assert entry.metadata["connections"] == 1
      assert entry.metadata["method"] == "password_form"
    end

    test "writes no entry when there was nothing to end", %{user: user} do
      assert {:ok, _} = Auth.update_user_password(user, @current, @attrs)

      assert activity_count(user) == 0
    end

    test "a refused change (wrong current password) ends nothing", %{user: user, scope: scope} do
      held = holdings(user, scope)

      assert {:error, %Ecto.Changeset{}} = Auth.update_user_password(user, "wrong", @attrs)

      assert_everything_alive(held)
    end

    test "the keys' cache is cleared again after the commit", %{user: user, scope: scope} do
      held = holdings(user, scope)

      calls =
        invalidations(fn ->
          assert {:ok, _} = Auth.update_user_password(user, @current, @attrs)
        end)

      assert_cleared_twice(calls, held)
    end
  end

  # Calls of `Cache.invalidate/1` made by `fun`, as the list of prefixes. A process is never traced
  # by itself: a helper receives the calls and passes them on.
  defp invalidations(fun) do
    test_pid = self()

    tracer =
      spawn_link(fn ->
        forward = fn forward ->
          receive do
            {:trace, _pid, :call, {Cache, :invalidate, [prefix]}} ->
              send(test_pid, {:invalidated, prefix})
              forward.(forward)
          end
        end

        forward.(forward)
      end)

    {:module, Cache} = Code.ensure_loaded(Cache)
    assert :erlang.trace_pattern({Cache, :invalidate, 1}, true, [:local]) == 1
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Cache, :invalidate, 1}, false, [:local])
    end

    invalidated()
  end

  # Once inside the transaction (by the revocation), once after it.
  defp assert_cleared_twice(calls, held) do
    for prefix <- [held.personal.prefix, held.hidden.prefix] do
      assert Enum.count(calls, &(&1 == prefix)) >= 2, "cache of #{prefix}"
    end
  end

  defp invalidated(calls \\ []) do
    receive do
      {:invalidated, prefix} -> invalidated([prefix | calls])
    after
      200 -> calls
    end
  end

  defp entries(user) do
    Activity.list(action: "api.revoked_on_password_change", resource_uuid: user.uuid).entries
  end

  # A grant whose code was never exchanged: a consent nobody finished.
  defp new_grant(scope) do
    client = client!()

    attrs = %{
      scopes: [read_scope()],
      expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second),
      approved?: true
    }

    Grants.create(scope, client, attrs, impersonated: false)
  end

  describe "on, the other paths" do
    setup do
      switch(true)
    end

    test "a reset by a token", %{user: user, scope: scope} do
      held = holdings(user, scope)

      assert {:ok, _} = Auth.reset_user_password(user, @attrs)

      assert_everything_ended(held)
      assert entry_method(user) == "reset_token"
    end

    test "a change by an administrator", %{user: user, scope: scope} do
      held = holdings(user, scope)
      admin = owner_user()

      assert {:ok, _} = Auth.admin_update_user_password(user, @attrs, %{admin_user: admin})

      assert_everything_ended(held)
      assert entry_method(user) == "admin_reset"
    end

    test "the entry of each key names the administrator", %{user: user, scope: scope} do
      held = holdings(user, scope)
      admin = owner_user()

      assert {:ok, _} = Auth.admin_update_user_password(user, @attrs, %{admin_user: admin})

      assert [entry] =
               Activity.list(action: "api.key_revoked", resource_uuid: held.personal.uuid).entries

      assert entry.actor_uuid == admin.uuid
    end

    test "a change by the system, with no actor named", %{user: user, scope: scope} do
      held = holdings(user, scope)

      assert {:ok, _} = Auth.admin_update_user_password(user, @attrs)

      assert_everything_ended(held)
    end

    test "the rotation of the confirmation by an external proof", %{user: user, scope: scope} do
      held = holdings(user, scope)
      unconfirmed = user |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()

      assert {:ok, confirmed} = Auth.confirm_user_from_external_proof(unconfirmed)

      assert confirmed.confirmed_at
      assert_everything_ended(held)
      assert entry_method(user) == "external_proof"
    end

    for path <- [:reset, :admin, :system, :external_proof] do
      test "the keys' cache is cleared again after the commit (#{path})", %{
        user: user,
        scope: scope
      } do
        held = holdings(user, scope)

        calls =
          invalidations(fn -> assert {:ok, _} = run_path(unquote(path), user) end)

        assert_cleared_twice(calls, held)
      end
    end

    test "an already confirmed person is left as is", %{user: user, scope: scope} do
      held = holdings(user, scope)

      assert {:ok, _} = Auth.confirm_user_from_external_proof(Repo.get!(User, user.uuid))

      assert_everything_alive(held)
    end
  end

  defp run_path(:reset, user), do: Auth.reset_user_password(user, @attrs)

  defp run_path(:admin, user),
    do: Auth.admin_update_user_password(user, @attrs, %{admin_user: owner_user()})

  defp run_path(:system, user), do: Auth.admin_update_user_password(user, @attrs)

  defp run_path(:external_proof, user) do
    user
    |> Ecto.Changeset.change(confirmed_at: nil)
    |> Repo.update!()
    |> Auth.confirm_user_from_external_proof()
  end

  defp entry_method(user) do
    [entry] = entries(user)
    entry.metadata["method"]
  end

  describe "a first password" do
    setup do
      switch(true)
    end

    # The column is NOT NULL: a person who signs in with a passkey, a magic link or a provider
    # holds a random hash, so there is no way to tell their first password from a change. It
    # ends their keys and connections like any other change, and the setting says so.
    test "of a person with a random hash ends their keys and connections", %{
      user: user,
      scope: scope
    } do
      held = holdings(user, scope)
      random = Bcrypt.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(32)))

      Repo.update_all(from(u in User, where: u.uuid == ^user.uuid),
        set: [hashed_password: random]
      )

      assert {:ok, _} = Auth.admin_update_user_password(Repo.get!(User, user.uuid), @attrs)

      assert_everything_ended(held)
    end

    test "of a struct that carries no hash still ends them", %{user: user, scope: scope} do
      held = holdings(user, scope)
      unconfirmed = user |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()

      assert {:ok, _} =
               Auth.confirm_user_from_external_proof(%{unconfirmed | hashed_password: nil})

      assert_everything_ended(held)
    end
  end

  describe "a failure of the revocation" do
    setup do
      switch(true)
    end

    # A trigger that skips the update of a key: the revocation finds nothing it can end.
    test "of a key gives back an error and keeps the old password", %{user: user, scope: scope} do
      held = holdings(user, scope)
      before = hash_of(user)
      skip_updates!("phoenix_kit_api_keys", "uuid = '#{held.personal.uuid}'")

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Auth.update_user_password(user, @current, @attrs)

      assert Keyword.has_key?(errors, :password)
      assert hash_of(user) == before
      assert alive?(held.personal)
      assert alive?(held.grant)
    end

    test "of a connection gives back an error and keeps the old password", %{
      user: user,
      scope: scope
    } do
      held = holdings(user, scope)
      before = hash_of(user)
      skip_updates!("phoenix_kit_api_oauth_grants", "uuid = '#{held.grant.uuid}'")

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Auth.update_user_password(user, @current, @attrs)

      assert Keyword.has_key?(errors, :password)

      assert hash_of(user) == before
      assert alive?(held.personal)
      assert alive?(held.grant)
    end
  end

  defp skip_updates!(table, condition) do
    name = "skip_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN RETURN NULL; END; $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{name} BEFORE UPDATE ON #{table}
    FOR EACH ROW WHEN (OLD.#{condition}) EXECUTE FUNCTION #{name}()
    """)
  end
end
