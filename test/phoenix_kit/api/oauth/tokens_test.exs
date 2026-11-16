defmodule PhoenixKit.API.OAuth.TokensTest do
  @moduledoc """
  OAuth access tokens on the resource side: the token format, and `Tokens.verify/2` against
  **seeded** grants (there is no authorization flow in these tests). The point of the file is
  what ends a token: its own time, its grant, its key and, above all, its owner's rights read
  again on every request.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.Users.Permissions

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, role, scope} = oauth_holder(["media", "media.manage"])
    seed = seed_grant!(scope, scopes: [read_scope(), write_scope()])
    %{user: user, role: role, scope: scope, seed: seed}
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)

  defp set_token(row, fields),
    do: Repo.update_all(from(t in Token, where: t.uuid == ^row.uuid), set: fields)

  defp set_grant(grant, fields),
    do: Repo.update_all(from(g in Grant, where: g.uuid == ^grant.uuid), set: fields)

  describe "the format" do
    test "generate/1 gives pkoa_ and pkor_ tokens of 32 random bytes, and parse/1 reads them back" do
      {access, access_hash} = Tokens.generate(:access)
      {refresh, refresh_hash} = Tokens.generate(:refresh)

      assert access =~ ~r/\Apkoa_[A-Za-z0-9_-]{43}\z/
      assert refresh =~ ~r/\Apkor_[A-Za-z0-9_-]{43}\z/
      assert {:ok, :access, ^access_hash} = Tokens.parse(access)
      assert {:ok, :refresh, ^refresh_hash} = Tokens.parse(refresh)
      assert byte_size(access_hash) == 32
      assert access != elem(Tokens.generate(:access), 0)
    end

    test "parse/1 refuses anything that is not canonical" do
      {access, _hash} = Tokens.generate(:access)
      [_, secret] = String.split(access, "pkoa_")

      for bad <- [
            nil,
            1,
            "",
            "pkoa_",
            "pkoa_" <> String.slice(secret, 0, 42),
            "pkoa_" <> secret <> "A",
            "pkoa_" <> String.replace(secret, ~r/.$/, "="),
            "PKOA_" <> secret,
            "pk_abcdef01_" <> secret,
            "pkox_" <> secret,
            " " <> access,
            access <> "\n"
          ] do
        assert Tokens.parse(bad) == :error
      end
    end

    test "access_token?/1 only reads the scheme" do
      assert Tokens.access_token?("pkoa_whatever")
      refute Tokens.access_token?("pkor_x")
      refute Tokens.access_token?("pk_x")
      refute Tokens.access_token?(nil)
    end

    test "only a hash is stored", %{seed: seed} do
      refute seed.access_row.token_hash == seed.access
      assert {:ok, :access, hash} = Tokens.parse(seed.access)
      assert seed.access_row.token_hash == hash
      assert Repo.get!(Token, seed.access_row.uuid).token_hash == hash
    end
  end

  describe "issue/3" do
    test "an access token lives the configured time, a refresh token as long as the grant", %{
      seed: seed
    } do
      put_setting("api_oauth_access_ttl_seconds", 600)
      {:ok, _token, access} = Tokens.issue(seed.grant, :access)
      {:ok, _token, refresh} = Tokens.issue(seed.grant, :refresh)

      assert_in_delta DateTime.diff(access.expires_at, DateTime.utc_now()), 600, 5
      assert refresh.expires_at == seed.grant.expires_at
      assert access.kind == "access" and refresh.kind == "refresh"
    end

    test "no token outlives its grant", %{seed: seed} do
      put_setting("api_oauth_access_ttl_seconds", 86_400)
      near = DateTime.add(DateTime.utc_now(), 120, :second) |> DateTime.truncate(:second)
      set_grant(seed.grant, expires_at: near)

      {:ok, _token, access} = Tokens.issue(Repo.get!(Grant, seed.grant.uuid), :access)
      assert access.expires_at == near
    end

    test "the lifetime is held between five minutes and a day", %{seed: seed} do
      put_setting("api_oauth_access_ttl_seconds", 1)
      {:ok, _token, short} = Tokens.issue(seed.grant, :access)
      assert_in_delta DateTime.diff(short.expires_at, DateTime.utc_now()), 300, 5

      put_setting("api_oauth_access_ttl_seconds", 10_000_000)
      {:ok, _token, long} = Tokens.issue(seed.grant, :access)
      assert_in_delta DateTime.diff(long.expires_at, DateTime.utc_now()), 86_400, 5
    end

    test "carries the family and the parent of a retried refresh", %{seed: seed} do
      {:ok, _token, child} =
        Tokens.issue(seed.grant, :refresh,
          family: seed.refresh_row.family,
          parent_uuid: seed.refresh_row.uuid
        )

      assert child.family == seed.refresh_row.family
      assert child.parent_uuid == seed.refresh_row.uuid
    end
  end

  describe "verify/2 of a live token" do
    test "returns the actor of the grant's key with the narrowed scopes", %{
      seed: seed,
      user: user
    } do
      assert {:ok, %Actor{} = actor} = Tokens.verify(seed.access, "203.0.113.9")

      assert actor.kind == :key
      assert actor.key_uuid == seed.key.uuid
      assert actor.key_prefix == seed.key.prefix
      assert actor.user_uuid == user.uuid
      assert actor.scopes == [read_scope(), write_scope()]
      assert actor.personal
      refute actor.requires_approval
      assert actor.ip == "203.0.113.9"
    end

    test "scopes are the grant's, narrowed by the owner's rights as they are now", %{
      seed: seed,
      role: role
    } do
      :ok = Permissions.revoke_permission(role.uuid, "media.manage")

      assert {:ok, actor} = Tokens.verify(seed.access, nil)
      assert actor.scopes == [read_scope()]
    end

    test "never wider than the grant, whatever the owner may do", %{scope: scope} do
      narrow = seed_grant!(scope, scopes: [read_scope()])
      assert {:ok, actor} = Tokens.verify(narrow.access, nil)
      assert actor.scopes == [read_scope()]
    end

    test "a key row wider than its grant is cut to the grant", %{scope: scope} do
      narrow = seed_grant!(scope, scopes: [read_scope()])

      # The key row says more than the grant does (set directly: nothing but a bug makes it so).
      Repo.update_all(from(k in Keys.Key, where: k.uuid == ^narrow.key.uuid),
        set: [scopes: [read_scope(), write_scope()]]
      )

      assert {:ok, actor} = Tokens.verify(narrow.access, nil)
      assert actor.scopes == [read_scope()]
    end

    test "writes last_used_at of the grant, at most once a minute", %{seed: seed} do
      assert Repo.get!(Grant, seed.grant.uuid).last_used_at == nil
      assert {:ok, _} = Tokens.verify(seed.access, nil)
      assert %DateTime{} = Repo.get!(Grant, seed.grant.uuid).last_used_at

      set_grant(seed.grant, last_used_at: nil)
      assert {:ok, _} = Tokens.verify(seed.access, nil)
      assert Repo.get!(Grant, seed.grant.uuid).last_used_at == nil
    end
  end

  describe "verify/2 refuses" do
    test "garbage, a refresh token, a pk_ key and a token nobody issued", %{seed: seed} do
      {unknown, _} = Tokens.generate(:access)
      {:ok, {_key, pk_token}} = {:ok, issue_key!(owner_user(), [read_scope()])}

      for bad <- [nil, "", "x", seed.refresh, pk_token, unknown, seed.access <> "x"] do
        assert {:error, :invalid_token} = Tokens.verify(bad, nil)
      end
    end

    test "a refresh secret under the access prefix, and an access secret under the refresh one",
         %{seed: seed} do
      "pkor_" <> refresh_secret = seed.refresh
      "pkoa_" <> access_secret = seed.access

      assert {:error, :invalid_token} = Tokens.verify("pkoa_" <> refresh_secret, nil)
      assert {:error, :invalid_token} = Tokens.verify("pkor_" <> access_secret, nil)

      # The kind is part of the hash: the same secret is a different token under each prefix.
      {:ok, :access, access_as_access} = Tokens.parse("pkoa_" <> access_secret)
      {:ok, :refresh, access_as_refresh} = Tokens.parse("pkor_" <> access_secret)
      refute access_as_access == access_as_refresh
    end

    test "a refresh row is no access token even when its hash was made the access way", %{
      seed: seed
    } do
      # The kind filter of the lookup is the second barrier: a row of the refresh kind that
      # carries an access-style hash (a future code path mixing the two up) still never verifies.
      "pkor_" <> refresh_secret = seed.refresh
      {:ok, secret} = Base.url_decode64(refresh_secret, padding: false)
      set_token(seed.refresh_row, token_hash: Tokens.hash(:access, secret))

      assert {:error, :invalid_token} = Tokens.verify("pkoa_" <> refresh_secret, nil)
    end

    test "a revoked token", %{seed: seed} do
      set_token(seed.access_row, revoked_at: past(), revoke_reason: "rotated")
      assert {:error, :revoked} = Tokens.verify(seed.access, nil)
    end

    test "an expired token, which is the normal end of an hour", %{seed: seed} do
      set_token(seed.access_row, expires_at: past())
      assert {:error, :expired} = Tokens.verify(seed.access, nil)
    end

    test "a token whose grant was revoked, at once and without the key cache", %{seed: seed} do
      assert {:ok, _} = Tokens.verify(seed.access, nil)
      assert {:ok, _} = Grants.revoke(seed.grant)
      assert {:error, :revoked} = Tokens.verify(seed.access, nil)
    end

    test "a token inserted after its grant was revoked is dead the moment it is used", %{
      seed: seed
    } do
      # The refresh racing a revocation: the revoking statement has run, then a token appears.
      {:ok, _} = Grants.revoke(seed.grant)
      {:ok, late, _row} = Tokens.issue(Repo.get!(Grant, seed.grant.uuid), :access)

      assert {:error, :revoked} = Tokens.verify(late, nil)
    end

    test "a token whose grant row changed under it, with no help from Keys", %{seed: seed} do
      assert {:ok, _} = Tokens.verify(seed.access, nil)
      set_grant(seed.grant, revoked_at: past())
      assert {:error, :revoked} = Tokens.verify(seed.access, nil)
    end

    test "a grant past its end", %{seed: seed} do
      set_grant(seed.grant, expires_at: past())
      assert {:error, :expired} = Tokens.verify(seed.access, nil)
    end

    test "a grant for another resource", %{scope: scope} do
      other = seed_grant!(scope, resource: "https://elsewhere.example/mcp/admin")
      assert {:error, :invalid_token} = Tokens.verify(other.access, nil)
    end

    test "a grant whose key row no longer points back at it", %{seed: seed} do
      Repo.update_all(from(k in Keys.Key, where: k.uuid == ^seed.key.uuid),
        set: [oauth_grant_uuid: UUIDv7.generate()]
      )

      assert {:error, :invalid_token} = Tokens.verify(seed.access, nil)
    end

    test "a key that expired or was revoked behind the grant's back", %{seed: seed} do
      Repo.update_all(from(k in Keys.Key, where: k.uuid == ^seed.key.uuid),
        set: [expires_at: past()]
      )

      assert {:error, :expired} = Tokens.verify(seed.access, nil)

      Repo.update_all(from(k in Keys.Key, where: k.uuid == ^seed.key.uuid),
        set: [revoked_at: past()]
      )

      assert {:error, :revoked} = Tokens.verify(seed.access, nil)
    end

    test "an owner who is blocked", %{seed: seed, user: user} do
      user |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :owner_inactive} = Tokens.verify(seed.access, nil)
        end)

      assert log =~ "Inactive user"
    end

    test "an owner whose role lost api_personal_keys, while keeping every module right", %{
      seed: seed,
      role: role
    } do
      assert {:ok, _} = Tokens.verify(seed.access, nil)

      :ok = Permissions.revoke_permission(role.uuid, "api_personal_keys")

      assert {:error, :personal_keys_not_allowed} = Tokens.verify(seed.access, nil)

      # Giving it back revives the grant: the right is read, not remembered.
      {:ok, _} = Permissions.grant_permission(role.uuid, "api_personal_keys")
      assert {:ok, _} = Tokens.verify(seed.access, nil)
    end
  end

  describe "the grant's key is the grant's alone" do
    test "Keys.verify/2 never takes an OAuth token, and Tokens.verify/2 never takes a pk_ key", %{
      seed: seed
    } do
      assert {:error, :invalid_token} = Keys.verify(seed.access, nil)
      assert {:error, :invalid_token} = Keys.verify(seed.refresh, nil)
    end
  end
end
