defmodule PhoenixKit.API.PersonalKeysConcurrencyTest do
  @moduledoc """
  The per-person cap of live personal keys under real concurrency: separate database
  sessions, real commits, no sandbox. Simultaneous creations must not pass the cap
  together (`Keys.create_personal_key/3` counts and inserts under one advisory lock per
  person).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  @moduletag :integration

  @callers 8
  @cap 3

  setup do
    Sandbox.mode(Repo, :auto)
    KeyTestSupport.start_cache_registry!()

    {:ok, role} = Roles.create_role(%{name: "PkRace#{System.unique_integer([:positive])}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "api_personal_keys")
    user = KeyTestSupport.register_user!()
    {:ok, _} = Roles.assign_role(user, role.name)

    KeyTestSupport.put_setting("api_personal_key_max_count", @cap)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      key_uuids = Repo.all(from(k in Key, where: k.user_uuid == ^user.uuid, select: k.uuid))

      Repo.delete_all(
        from(e in PhoenixKit.Activity.Entry,
          where: e.actor_uuid == ^user.uuid or e.resource_uuid in ^key_uuids
        )
      )

      # Keys, role assignments and tokens go with the user; permissions with the role.
      Repo.delete_all(from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^user.uuid))
      Repo.delete_all(from(r in PhoenixKit.Users.Role, where: r.uuid == ^role.uuid))
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = 'api_personal_key_max_count'")
      Sandbox.mode(Repo, :manual)
    end)

    %{user: user}
  end

  test "simultaneous creations never pass the cap", %{user: user} do
    scope = Scope.for_user(Auth.get_user(user.uuid), narrow: false)
    expires_at = DateTime.new!(Date.add(Date.utc_today(), 10), ~T[23:59:59], "Etc/UTC")

    results =
      1..@callers
      |> Enum.map(fn n ->
        Task.async(fn ->
          Keys.create_personal_key(scope, %{name: "race #{n}", expires_at: expires_at},
            impersonated: false
          )
        end)
      end)
      |> Task.await_many(30_000)

    created = Enum.count(results, &match?({:ok, _key, _token}, &1))
    refused = Enum.count(results, &(&1 == {:error, :personal_key_limit}))

    assert created == @cap
    assert refused == @callers - @cap
    assert Repo.aggregate(from(k in Key, where: k.user_uuid == ^user.uuid), :count) == @cap
  end
end
