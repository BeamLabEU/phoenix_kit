defmodule PhoenixKit.API.PersonalKeysTest do
  @moduledoc """
  Personal API keys (`personal = true`): a person's own key, created through
  `Keys.create_personal_key/3` by a holder of `api_personal_keys` (or `api`), working with
  that person's rights only while they hold one of those permissions. Their limits (expiry
  required and capped, no approval, a count per person), the rules of who may manage,
  revoke, rotate and narrow them, and the unchanged behaviour of every other key.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.ServiceUsers
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions

  @right "api_personal_keys"

  setup do
    register_fake_module!()
    start_key_cache!()
    owner = owner_user()
    %{owner: owner, owner_scope: scope_of(owner)}
  end

  defp end_of_day(days),
    do: DateTime.new!(Date.add(Date.utc_today(), days), ~T[23:59:59], "Etc/UTC")

  # A person holding the new permission (and not `api`) plus `permissions`.
  defp holder(permissions \\ ["media"]) do
    {user, role} = user_without_api([@right | permissions])
    {user, role, scope_of(user)}
  end

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        name: "Agent #{System.unique_integer([:positive])}",
        scopes: [read_scope()],
        expires_at: end_of_day(30)
      },
      extra
    )
  end

  defp personal!(scope, extra \\ %{}) do
    {:ok, key, token} = Keys.create_personal_key(scope, attrs(extra), impersonated: false)
    {key, token}
  end

  defp live_personal_count(owner_uuid) do
    now = DateTime.utc_now()

    Repo.aggregate(
      from(k in Key,
        where:
          k.user_uuid == ^owner_uuid and k.personal and
            (is_nil(k.revoked_at) or k.revoked_at > ^now)
      ),
      :count
    )
  end

  defp entries(action, key) do
    Repo.all(from(e in Entry, where: e.action == ^action and e.resource_uuid == ^key.uuid))
  end

  defp errors_on_field(%Ecto.Changeset{} = changeset, field),
    do: changeset |> errors_on() |> Map.get(field, [])

  describe "create_personal_key/3" do
    test "a holder of the permission creates a key for themselves; the token is returned once" do
      {user, _role, scope} = holder()

      assert {:ok, %Key{} = key, token} =
               Keys.create_personal_key(scope, attrs(), impersonated: false)

      assert token =~ ~r/\Apk_[0-9a-f]{8}_[A-Za-z0-9_-]{43}\z/
      assert key.personal
      assert key.user_uuid == user.uuid
      assert key.created_by_uuid == user.uuid
      refute key.requires_approval
      assert key.scopes == [read_scope()]
      assert Repo.get!(Key, key.uuid).personal

      assert [entry] = entries("api.key_created", key)
      assert entry.metadata["personal"] == true
      secret = token |> String.split("_", parts: 3) |> List.last()
      refute inspect(entry.metadata) =~ secret
    end

    test "the impersonation flag is required and has no default" do
      {_user, _role, scope} = holder()

      assert {:error, :impersonation_unknown} = Keys.create_personal_key(scope, attrs(), [])

      assert {:error, :impersonation_unknown} =
               Keys.create_personal_key(scope, attrs(), impersonated: "false")

      assert {:error, :impersonated} =
               Keys.create_personal_key(scope, attrs(), impersonated: true)

      assert Repo.aggregate(from(k in Key, where: k.user_uuid == ^scope.user.uuid), :count) == 0
    end

    test "a person with neither permission is refused" do
      {user, _role} = user_without_api(["media"])

      assert {:error, :forbidden} =
               Keys.create_personal_key(scope_of(user), attrs(), impersonated: false)

      assert {:error, :forbidden} = Keys.create_personal_key(nil, attrs(), impersonated: false)
    end

    test "a holder of api may take the personal path too, with its limits" do
      {_user, _role, scope} = api_holder(["media"])

      assert {:ok, key, _token} = Keys.create_personal_key(scope, attrs(), impersonated: false)
      assert key.personal

      assert {:error, %Ecto.Changeset{} = changeset} =
               Keys.create_personal_key(scope, attrs(%{expires_at: nil}), impersonated: false)

      assert errors_on_field(changeset, :expires_at) != []
    end

    test "the expiry is required and capped at the end of the UTC day max_days from today" do
      {_user, _role, scope} = holder()

      for expires_at <- [nil, end_of_day(91), DateTime.add(DateTime.utc_now(), -60)] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Keys.create_personal_key(scope, attrs(%{expires_at: expires_at}),
                   impersonated: false
                 )

        assert errors_on_field(changeset, :expires_at) != [], inspect(expires_at)
      end

      assert {:error, %Ecto.Changeset{}} =
               Keys.create_personal_key(scope, Map.delete(attrs(), :expires_at),
                 impersonated: false
               )

      assert {:ok, key, _} =
               Keys.create_personal_key(scope, attrs(%{expires_at: end_of_day(90)}),
                 impersonated: false
               )

      assert key.expires_at == end_of_day(90)
    end

    test "a lower ceiling is read when the key is created" do
      {_user, _role, scope} = holder()
      put_setting("api_personal_key_max_days", 7)

      assert {:error, %Ecto.Changeset{}} =
               Keys.create_personal_key(scope, attrs(%{expires_at: end_of_day(8)}),
                 impersonated: false
               )

      assert {:ok, _key, _} =
               Keys.create_personal_key(scope, attrs(%{expires_at: end_of_day(7)}),
                 impersonated: false
               )
    end

    test "requires_approval true is an error, not silently dropped" do
      {_user, _role, scope} = holder()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Keys.create_personal_key(scope, attrs(%{requires_approval: true}),
                 impersonated: false
               )

      assert errors_on_field(changeset, :requires_approval) != []

      assert {:error, %Ecto.Changeset{}} =
               Keys.create_personal_key(
                 scope,
                 %{
                   "name" => "form",
                   "expires_at" => end_of_day(10),
                   "requires_approval" => "true"
                 },
                 impersonated: false
               )

      assert {:ok, key, _} =
               Keys.create_personal_key(scope, attrs(%{requires_approval: false}),
                 impersonated: false
               )

      refute key.requires_approval
    end

    test "a scope outside the person's rights is :invalid_scopes" do
      {_user, _role, scope} = holder(["media"])

      assert {:error, :invalid_scopes} =
               Keys.create_personal_key(scope, attrs(%{scopes: [write_scope()]}),
                 impersonated: false
               )

      assert {:error, :invalid_scopes} =
               Keys.create_personal_key(scope, attrs(%{scopes: ["nope.things:read"]}),
                 impersonated: false
               )
    end

    test "the owner is always the person: a service user's scope cannot take the path" do
      {role, _} = role_with([@right, "media"])
      service_user = service_user_with([role.name])

      assert {:error, :owner_not_allowed} =
               Keys.create_personal_key(scope_of(service_user), attrs(), impersonated: false)
    end

    test "a person who has not confirmed their address is refused while confirmation is required" do
      {user, _role, scope} = holder()
      Repo.update_all(from(u in User, where: u.uuid == ^user.uuid), set: [confirmed_at: nil])

      assert {:error, :owner_inactive} =
               Keys.create_personal_key(scope, attrs(), impersonated: false)
    end

    test "a person blocked since the scope was built is refused" do
      {user, _role, scope} = holder()
      {:ok, _} = Auth.update_user_status(user, %{is_active: false})

      assert {:error, :owner_inactive} =
               Keys.create_personal_key(scope, attrs(), impersonated: false)
    end

    test "the number of live personal keys is capped; revoked and expired ones do not count" do
      {user, _role, scope} = holder()
      put_setting("api_personal_key_max_count", 2)

      {first, _} = personal!(scope)
      {_second, _} = personal!(scope)

      assert {:error, :personal_key_limit} =
               Keys.create_personal_key(scope, attrs(), impersonated: false)

      {:ok, _} = Keys.revoke(first, user.uuid)
      {third, _} = personal!(scope)

      Repo.update_all(from(k in Key, where: k.uuid == ^third.uuid),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -5) |> DateTime.truncate(:second)]
      )

      assert {:ok, _fourth, _} = Keys.create_personal_key(scope, attrs(), impersonated: false)

      assert {:error, :personal_key_limit} =
               Keys.create_personal_key(scope, attrs(), impersonated: false)
    end

    test "a key in the grace period of a rotation still counts" do
      {_user, _role, scope} = holder()
      put_setting("api_personal_key_max_count", 2)

      {key, _} = personal!(scope)
      {:ok, _new, _token} = Keys.rotate(key, 5, scope, impersonated: false)

      assert {:error, :personal_key_limit} =
               Keys.create_personal_key(scope, attrs(), impersonated: false)
    end

    test "keys that are not personal do not count" do
      {user, _role, scope} = api_holder(["media"])
      put_setting("api_personal_key_max_count", 1)
      _plain = issue_key!(user, [read_scope()])

      assert {:ok, _key, _} = Keys.create_personal_key(scope, attrs(), impersonated: false)
    end
  end

  describe "create_key/3 stays as it was" do
    test "personal cannot be set through attrs", ctx do
      assert {:ok, key, _} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{
                 name: "plain",
                 scopes: [read_scope()],
                 personal: true
               })

      refute key.personal

      assert {:ok, key, _} =
               Keys.create_key(ctx.owner, ctx.owner_scope, %{
                 "name" => "plain",
                 "personal" => "true"
               })

      refute key.personal
      assert [entry] = entries("api.key_created", key)
      assert entry.metadata["personal"] == false
    end

    test "a holder of only api_personal_keys cannot use it" do
      {user, _role, scope} = holder()
      assert {:error, :forbidden} = Keys.create_key(user, scope, %{name: "plain"})
    end

    test "an api holder's key on themselves has no expiry limit and may need approval" do
      {user, _role, scope} = api_holder(["media"])

      assert {:ok, key, _} =
               Keys.create_key(user, scope, %{name: "plain", requires_approval: true})

      assert key.expires_at == nil
      assert key.requires_approval
      refute key.personal
    end
  end

  describe "verify/2" do
    test "a personal key works while its owner holds the permission" do
      {user, _role, scope} = holder()
      {_key, token} = personal!(scope)

      assert {:ok, %Actor{} = actor} = Keys.verify(token, "203.0.113.1")
      assert actor.personal
      assert actor.user_uuid == user.uuid
      assert actor.scopes == [read_scope()]
    end

    test "taking the permission from the role stops the key on the next request, whatever the cache holds" do
      {_user, role, scope} = holder()
      {_key, token} = personal!(scope)
      assert {:ok, _actor} = Keys.verify(token, nil)

      :ok = Permissions.revoke_permission(role.uuid, @right)
      assert {:error, :personal_keys_not_allowed} = Keys.verify(token, nil)

      {:ok, _} = Permissions.grant_permission(role.uuid, @right)
      assert {:ok, _actor} = Keys.verify(token, nil)
    end

    test "api instead of the permission keeps it working" do
      {_user, role, scope} = holder()
      {:ok, _} = Permissions.grant_permission(role.uuid, "api")
      {_key, token} = personal!(scope)

      :ok = Permissions.revoke_permission(role.uuid, @right)
      assert {:ok, _actor} = Keys.verify(token, nil)

      :ok = Permissions.revoke_permission(role.uuid, "api")
      assert {:error, :personal_keys_not_allowed} = Keys.verify(token, nil)
    end

    test "a blocked owner is :owner_inactive, as before" do
      {user, _role, scope} = holder()
      {_key, token} = personal!(scope)
      {:ok, _} = Auth.update_user_status(user, %{is_active: false})

      assert {:error, :owner_inactive} = Keys.verify(token, nil)
    end

    test "a key that is not personal keeps working after its owner loses api (unchanged)" do
      {user, role, _scope} = api_holder(["media"])
      {_key, token} = issue_key!(user, [read_scope()])

      :ok = Permissions.revoke_permission(role.uuid, "api")

      assert {:ok, %Actor{personal: false, scopes: [scope]}} = Keys.verify(token, nil)
      assert scope == read_scope()
    end
  end

  describe "the token-less paths check the permission too, in their old shapes" do
    test "active_owner/1, active?/1, actor/3, effective_scopes/1 and Confirm.live_actor/1" do
      {user, role, scope} = holder()
      {key, _token} = personal!(scope)

      assert {:ok, %User{uuid: uuid}} = Keys.active_owner(key)
      assert uuid == user.uuid
      assert Keys.active?(key)
      assert Keys.effective_scopes(key) == [read_scope()]
      assert {:ok, %Actor{personal: true, scopes: [_]} = actor} = Confirm.live_actor(key.uuid)
      assert Keys.effective_scopes(actor) == [read_scope()]
      assert %Actor{personal: true, scopes: [_]} = Keys.actor(key, user, nil)

      :ok = Permissions.revoke_permission(role.uuid, @right)

      assert {:error, :personal_keys_not_allowed} = Keys.active_owner(key)
      refute Keys.active?(key)
      assert Keys.effective_scopes(key) == []
      assert Keys.effective_scopes(actor) == []
      assert {:error, :personal_keys_not_allowed} = Confirm.live_actor(key.uuid)
      # The builder never hands out scopes the permission does not cover.
      assert %Actor{personal: true, scopes: []} = Keys.actor(key, user, nil)
    end

    test "verify/2 and active_owner/1 give the same answer in every state, in the same shapes" do
      {user, role, scope} = holder()
      {key, token} = personal!(scope)

      assert {:ok, %User{uuid: uuid}} = Keys.active_owner(key)
      assert {:ok, %Actor{user_uuid: ^uuid, personal: true}} = Keys.verify(token, nil)

      :ok = Permissions.revoke_permission(role.uuid, @right)
      assert {:error, :personal_keys_not_allowed} = Keys.active_owner(key)
      assert {:error, :personal_keys_not_allowed} = Keys.verify(token, nil)

      {:ok, _} = Permissions.grant_permission(role.uuid, @right)
      {:ok, _} = Auth.update_user_status(user, %{is_active: false})
      assert {:error, :owner_inactive} = Keys.active_owner(key)
      assert {:error, :owner_inactive} = Keys.verify(token, nil)
    end

    test "for a key that is not personal they answer as before, with or without api" do
      {user, role, _scope} = api_holder(["media"])
      {key, token} = issue_key!(user, [read_scope()])
      :ok = Permissions.revoke_permission(role.uuid, "api")

      assert {:ok, %User{}} = Keys.active_owner(key)
      assert {:ok, %Actor{personal: false}} = Keys.verify(token, nil)

      {:ok, _} = Auth.update_user_status(user, %{is_active: false})
      assert {:error, :owner_inactive} = Keys.active_owner(key)
      assert {:error, :owner_inactive} = Keys.verify(token, nil)
    end

    test "for a key that is not personal they answer as before", ctx do
      {key, _token} = issue_key!(ctx.owner, [read_scope()])

      assert {:ok, %User{}} = Keys.active_owner(key)
      assert Keys.active?(key)
      assert {:ok, %Actor{kind: :key, personal: false}} = Confirm.live_actor(key.uuid)
      assert %Actor{personal: false} = Keys.actor(key, ctx.owner, "203.0.113.9")
      assert Keys.effective_scopes(key) == [read_scope()]
    end
  end

  describe "list_personal_keys/1" do
    test "the person's own personal keys only, newest first" do
      {user, _role, scope} = holder()
      {other, _role, other_scope} = holder()
      {first, _} = personal!(scope)
      {second, _} = personal!(scope)
      {_others, _} = personal!(other_scope)

      Repo.update_all(from(k in Key, where: k.uuid == ^first.uuid),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600) |> DateTime.truncate(:second)]
      )

      assert Enum.map(Keys.list_personal_keys(scope), & &1.uuid) == [second.uuid, first.uuid]
      assert Enum.all?(Keys.list_personal_keys(scope), &(&1.user_uuid == user.uuid))
      refute other.uuid == user.uuid
    end

    test "an api holder's keys that are not personal are not listed" do
      {user, _role, scope} = api_holder(["media"])
      _plain = issue_key!(user, [read_scope()])
      {personal, _} = personal!(scope)

      assert Enum.map(Keys.list_personal_keys(scope), & &1.uuid) == [personal.uuid]
    end

    test "an Owner sees only their own here; nobody without the permissions sees any", ctx do
      {_user, role, scope} = holder()
      personal!(scope)

      assert Keys.list_personal_keys(ctx.owner_scope) == []

      :ok = Permissions.revoke_permission(role.uuid, @right)
      user = Auth.get_user(scope.user.uuid)
      assert Keys.list_personal_keys(scope_of(user)) == []
      assert Keys.list_personal_keys(nil) == []
    end
  end

  describe "can_manage?/2 and can_revoke?/2" do
    test "the owner manages their own personal key while they hold a permission", ctx do
      {user, role, scope} = holder()
      {key, _} = personal!(scope)

      assert Keys.can_manage?(scope, key)
      assert Keys.can_revoke?(scope, key)

      :ok = Permissions.revoke_permission(role.uuid, @right)
      stale_free = scope_of(Auth.get_user(user.uuid))
      refute Keys.can_manage?(stale_free, key)
      refute Keys.can_revoke?(stale_free, key)

      refute Keys.can_manage?(ctx.owner_scope, key)
      assert Keys.can_revoke?(ctx.owner_scope, key)
    end

    test "another api holder can do neither" do
      {_user, _role, scope} = holder()
      {key, _} = personal!(scope)
      {_other, _role, api_scope} = api_holder(["media"])

      refute Keys.can_manage?(api_scope, key)
      refute Keys.can_revoke?(api_scope, key)
    end

    test "for keys that are not personal can_revoke? is can_manage?", ctx do
      {user, _role, scope} = api_holder(["media"])
      {key, _} = issue_key!(user, [read_scope()])

      assert Keys.can_manage?(scope, key) and Keys.can_revoke?(scope, key)
      assert Keys.can_manage?(ctx.owner_scope, key) and Keys.can_revoke?(ctx.owner_scope, key)
    end
  end

  describe "rotate/4 of a personal key" do
    test "the new key stays personal, expires at the ceiling and never needs approval" do
      {_user, _role, scope} = holder()
      {key, _} = personal!(scope, %{expires_at: end_of_day(3)})
      put_setting("api_personal_key_max_days", 20)

      before = end_of_day(20)
      assert {:ok, new_key, token} = Keys.rotate(key, 2, scope, impersonated: false)

      assert new_key.personal
      # Read around the rotation, so a run across UTC midnight still matches.
      assert new_key.expires_at in [before, end_of_day(20)]
      refute new_key.requires_approval
      assert new_key.scopes == key.scopes
      assert {:ok, %Actor{personal: true}} = Keys.verify(token, nil)

      old = Repo.get!(Key, key.uuid)
      assert DateTime.compare(old.revoked_at, DateTime.utc_now()) == :gt

      assert [entry] = entries("api.key_rotated", old)
      assert entry.metadata["personal"] == true
    end

    test "is refused without the impersonation flag, and in a borrowed session" do
      {_user, _role, scope} = holder()
      {key, _} = personal!(scope)

      assert {:error, :impersonation_unknown} = Keys.rotate(key, 0, scope)
      assert {:error, :impersonation_unknown} = Keys.rotate(key, 0, scope, [])
      assert {:error, :impersonated} = Keys.rotate(key, 0, scope, impersonated: true)
      assert Repo.get!(Key, key.uuid).revoked_at == nil
    end

    test "an Owner cannot rotate someone else's personal key, whatever the struct says", ctx do
      {_user, _role, scope} = holder()
      {key, _} = personal!(scope)

      assert {:error, :forbidden} = Keys.rotate(key, 0, ctx.owner_scope, impersonated: false)

      forged = %{key | personal: false, created_by_uuid: ctx.owner.uuid}
      assert {:error, :forbidden} = Keys.rotate(forged, 0, ctx.owner_scope, impersonated: false)
      assert Repo.get!(Key, key.uuid).revoked_at == nil
    end

    test "the owner's rights are read again: a scope from before losing them is not enough" do
      {_user, role, scope} = holder()
      {key, _} = personal!(scope)
      :ok = Permissions.revoke_permission(role.uuid, @right)

      assert {:error, :forbidden} = Keys.rotate(key, 0, scope, impersonated: false)
      assert Repo.get!(Key, key.uuid).revoked_at == nil
    end

    test "is a one-for-one swap: allowed at the limit" do
      {_user, _role, scope} = holder()
      put_setting("api_personal_key_max_count", 1)
      {key, _} = personal!(scope)

      assert {:ok, _new, _token} = Keys.rotate(key, 0, scope, impersonated: false)
    end

    test "with a grace period it needs room under the limit; the new key counts too" do
      {_user, _role, scope} = holder()
      put_setting("api_personal_key_max_count", 2)
      {key, _} = personal!(scope)

      assert {:ok, new_key, _token} = Keys.rotate(key, 5, scope, impersonated: false)

      # Two live keys now (the old one in its grace period): the limit is reached.
      assert {:error, :personal_key_limit} = Keys.rotate(new_key, 5, scope, impersonated: false)
      assert Repo.get!(Key, new_key.uuid).revoked_at == nil
      assert live_personal_count(new_key.user_uuid) == 2
    end

    test "a chain of rotations with a grace period cannot exceed the limit" do
      {_user, _role, scope} = holder()
      put_setting("api_personal_key_max_count", 3)
      {key, _} = personal!(scope)

      final =
        Enum.reduce(1..6, key, fn _step, current ->
          case Keys.rotate(current, 24, scope, impersonated: false) do
            {:ok, new_key, _token} -> new_key
            {:error, :personal_key_limit} -> current
          end
        end)

      assert live_personal_count(final.user_uuid) == 3
      assert {:error, :personal_key_limit} = Keys.rotate(final, 1, scope, impersonated: false)
    end

    test "at the limit a rotation without a grace period still works, any number of times" do
      {_user, _role, scope} = holder()
      put_setting("api_personal_key_max_count", 2)
      {first, _} = personal!(scope)
      {_second, _} = personal!(scope)

      assert {:error, :personal_key_limit} = Keys.rotate(first, 3, scope, impersonated: false)
      assert {:ok, again, _token} = Keys.rotate(first, 0, scope, impersonated: false)
      assert {:ok, _third, _token} = Keys.rotate(again, 0, scope, impersonated: false)
      assert live_personal_count(first.user_uuid) == 2
    end

    test "a key that is not personal ignores the limit when rotated with a grace period",
         ctx do
      put_setting("api_personal_key_max_count", 1)
      {key, _} = issue_key!(ctx.owner, [read_scope()])

      assert {:ok, new_key, _token} = Keys.rotate(key, 5, ctx.owner_scope)
      assert {:ok, _newer, _token} = Keys.rotate(new_key, 5, ctx.owner_scope)
    end

    test "a key that is not personal rotates as before through rotate/3", ctx do
      {key, _} = issue_key!(ctx.owner, [read_scope()], %{requires_approval: true})

      assert {:ok, new_key, _token} = Keys.rotate(key, 0, ctx.owner_scope)
      refute new_key.personal
      assert new_key.requires_approval
      assert new_key.expires_at == nil
    end
  end

  describe "update_scopes/3 of a personal key" do
    test "the owner changes their own within their rights" do
      {_user, _role, scope} = holder(["media", "media.manage"])
      {key, _} = personal!(scope)

      assert {:ok, updated} = Keys.update_scopes(key, [read_scope(), write_scope()], scope)
      assert Enum.sort(updated.scopes) == Enum.sort([read_scope(), write_scope()])
    end

    test "an Owner may only remove scopes, checked on the stored row", ctx do
      {_user, _role, scope} = holder(["media", "media.manage"])
      {key, _} = personal!(scope, %{scopes: [read_scope(), write_scope()]})

      assert {:error, :scopes_not_narrowing} =
               Keys.update_scopes(
                 key,
                 [read_scope(), write_scope(), run_scope()],
                 ctx.owner_scope
               )

      forged = %{key | scopes: [read_scope(), write_scope(), run_scope()], personal: false}

      assert {:error, :scopes_not_narrowing} =
               Keys.update_scopes(forged, [run_scope()], ctx.owner_scope)

      assert {:ok, updated} = Keys.update_scopes(key, [read_scope()], ctx.owner_scope)
      assert updated.scopes == [read_scope()]

      assert {:error, :scopes_not_narrowing} =
               Keys.update_scopes(key, [read_scope(), write_scope()], ctx.owner_scope)
    end

    test "an Owner's narrowing saves exactly what was asked: inactive scopes can go too", ctx do
      {user, role, scope} = holder(["media", "media.manage"])
      {key, _} = personal!(scope, %{scopes: [read_scope(), write_scope()]})
      :ok = Permissions.revoke_permission(role.uuid, "media.manage")

      assert {:ok, updated} = Keys.update_scopes(key, [read_scope()], ctx.owner_scope)
      assert updated.scopes == [read_scope()]

      {:ok, _} = Auth.update_user_status(user, %{is_active: false})
      assert {:ok, emptied} = Keys.update_scopes(key, [], ctx.owner_scope)
      assert emptied.scopes == []
    end

    test "another api holder cannot touch it" do
      {_user, _role, scope} = holder()
      {key, _} = personal!(scope)
      {_other, _role, api_scope} = api_holder(["media"])

      assert {:error, :forbidden} = Keys.update_scopes(key, [], api_scope)
    end
  end

  test "ServiceUsers stay closed to a holder of only the new permission" do
    {_user, _role, scope} = holder()

    assert ServiceUsers.list(scope) == []
    assert {:error, :forbidden} = ServiceUsers.create(scope, %{roles: []})
  end
end
