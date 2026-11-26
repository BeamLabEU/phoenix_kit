defmodule PhoenixKit.API.KeyRateLimitTest do
  @moduledoc """
  A key's own rate limit (`rate_limit_per_minute`, V238): it only ever lowers the shared
  `api_admin_rate_per_min`; `nil` (every existing key) is the shared limit exactly as
  before; `Keys.update_rate_limit/3` checks who may set it and what values it takes; the
  limit reaches the actor a request carries.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.KeyTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.RateLimit

  setup do
    wait_for_window_room()
    register_fake_module!()
    start_key_cache!()
    :ok
  end

  describe "RateLimit.check_admin/3" do
    test "without a key limit the bucket is the shared one, exactly as check_admin/2" do
      set_limit("api_admin_rate_per_min", 3)
      key_uuid = UUIDv7.generate()

      assert {:ok, headers} = RateLimit.check_admin(key_uuid, 1, nil)
      assert header_value(headers, "ratelimit-limit") == 3
      assert {:ok, _} = RateLimit.check_admin(key_uuid, 1)
      assert {:ok, _} = RateLimit.check_admin(key_uuid, 1, nil)
      assert {:error, _, _} = RateLimit.check_admin(key_uuid, 1)
    end

    test "a lower key limit holds the key below the shared one" do
      set_limit("api_admin_rate_per_min", 10)
      key_uuid = UUIDv7.generate()

      assert {:ok, headers} = RateLimit.check_admin(key_uuid, 1, 2)
      assert header_value(headers, "ratelimit-limit") == 2
      assert {:ok, _} = RateLimit.check_admin(key_uuid, 1, 2)
      assert {:error, retry_after, headers} = RateLimit.check_admin(key_uuid, 1, 2)
      assert retry_after in 1..60
      assert header_value(headers, "retry-after") == retry_after
    end

    test "a higher key limit never lifts the key above the shared one" do
      set_limit("api_admin_rate_per_min", 2)
      key_uuid = UUIDv7.generate()

      assert {:ok, headers} = RateLimit.check_admin(key_uuid, 1, 1_000)
      assert header_value(headers, "ratelimit-limit") == 2
      assert {:ok, _} = RateLimit.check_admin(key_uuid, 1, 1_000)
      assert {:error, _, _} = RateLimit.check_admin(key_uuid, 1, 1_000)
    end
  end

  describe "the key row and the actor" do
    test "a key made without a limit has none, and its actor carries none" do
      {owner, _role} = user_with(["media"])
      {key, token} = issue_key!(owner, [read_scope()])

      assert key.rate_limit_per_minute == nil
      assert {:ok, actor} = Keys.verify(token, unique_ip())
      assert actor.rate_limit_per_minute == nil
    end

    test "create_key takes a limit and refuses zero and negative ones" do
      {owner, _role} = user_with(["media"])
      {key, token} = issue_key!(owner, [read_scope()], %{rate_limit_per_minute: 7})

      assert key.rate_limit_per_minute == 7
      assert {:ok, %{rate_limit_per_minute: 7}} = Keys.verify(token, unique_ip())

      for bad <- [0, -1, 1_000_001] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Keys.create_key(owner, scope_of(owner), %{
                   name: "bad",
                   scopes: [read_scope()],
                   rate_limit_per_minute: bad
                 })

        assert changeset.errors[:rate_limit_per_minute]
      end
    end

    test "rotation keeps the limit" do
      {owner, _role} = user_with(["media"])
      {key, _token} = issue_key!(owner, [read_scope()], %{rate_limit_per_minute: 9})

      assert {:ok, new_key, _token} = Keys.rotate(key, 0, scope_of(owner), impersonated: false)
      assert new_key.rate_limit_per_minute == 9
    end
  end

  describe "Keys.update_rate_limit/3" do
    setup do
      {owner, _role} = user_with(["media"])
      {key, token} = issue_key!(owner, [read_scope()])
      %{owner: owner, key: key, token: token}
    end

    test "sets and clears the limit, drops the cached row, and logs the change", %{
      owner: owner,
      key: key,
      token: token
    } do
      assert {:ok, _actor} = Keys.verify(token, unique_ip())

      assert {:ok, %{rate_limit_per_minute: 5}} =
               Keys.update_rate_limit(key, 5, scope_of(owner))

      assert {:ok, %{rate_limit_per_minute: 5}} = Keys.verify(token, unique_ip())

      assert {:ok, %{rate_limit_per_minute: nil}} =
               Keys.update_rate_limit(key, nil, scope_of(owner))

      assert {:ok, %{rate_limit_per_minute: nil}} = Keys.verify(token, unique_ip())

      entries =
        Repo.all(
          from(a in Entry,
            where: a.action == "api.key_rate_limit_updated" and a.resource_uuid == ^key.uuid,
            order_by: a.inserted_at
          )
        )

      assert Enum.map(entries, &{&1.metadata["from"], &1.metadata["to"]}) == [
               {nil, 5},
               {5, nil}
             ]
    end

    test "saving the same value changes and logs nothing", %{owner: owner, key: key} do
      assert {:ok, _} = Keys.update_rate_limit(key, nil, scope_of(owner))

      refute Repo.exists?(
               from(a in Entry,
                 where: a.action == "api.key_rate_limit_updated" and a.resource_uuid == ^key.uuid
               )
             )
    end

    test "refuses zero, negative, too large and non-integer values", %{owner: owner, key: key} do
      for bad <- [0, -3, 1_000_001, "5", 2.5, :x] do
        assert Keys.update_rate_limit(key, bad, scope_of(owner)) == {:error, :invalid_rate_limit}
      end

      assert Keys.get_key(key.uuid).rate_limit_per_minute == nil
    end

    test "someone who may not manage the key is refused", %{key: key} do
      {other, _role} = user_with(["media"])
      assert Keys.update_rate_limit(key, 5, scope_of(other)) == {:error, :forbidden}
      assert Keys.get_key(key.uuid).rate_limit_per_minute == nil
    end

    test "a revoked key is refused", %{owner: owner, key: key} do
      {:ok, _} = Keys.revoke(key, owner.uuid)
      assert Keys.update_rate_limit(key, 5, scope_of(owner)) == {:error, :revoked}
    end
  end
end
