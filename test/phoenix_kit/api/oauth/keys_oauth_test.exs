defmodule PhoenixKit.API.KeysOAuthTest do
  @moduledoc """
  The hidden key of an OAuth grant inside `PhoenixKit.API.Keys`: how it is made, that it is
  invisible to everything that lists, counts, rotates or edits a person's keys, that it is
  never a `pk_` key, and that revoking it ends its grant.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport
  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.Keys.Token, as: KeyToken
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.Permissions

  setup do
    register_fake_module!()
    start_key_cache!()
    {user, role, scope} = oauth_holder(["media"])
    %{user: user, role: role, scope: scope}
  end

  defp grant_attrs(extra \\ %{}) do
    Map.merge(
      %{
        grant_uuid: UUIDv7.generate(),
        client_name: "Claude",
        scopes: [read_scope()],
        expires_at: DateTime.add(DateTime.utc_now(), 5 * 86_400, :second)
      },
      extra
    )
  end

  defp oauth_key_count,
    do: Repo.aggregate(from(k in Key, where: not is_nil(k.oauth_grant_uuid)), :count)

  defp entries(action, resource_uuid) do
    Repo.all(from(e in Entry, where: e.action == ^action and e.resource_uuid == ^resource_uuid))
  end

  describe "create_oauth_key/3" do
    test "makes a personal key bound to the grant uuid, with the grant's expiry", %{
      scope: scope,
      user: user
    } do
      attrs = grant_attrs()

      assert {:ok, %Key{} = key} = Keys.create_oauth_key(scope, attrs, impersonated: false)

      assert key.oauth_grant_uuid == attrs.grant_uuid
      assert key.personal
      refute key.requires_approval
      assert key.user_uuid == user.uuid
      assert key.created_by_uuid == user.uuid
      assert key.scopes == [read_scope()]
      assert key.expires_at == DateTime.truncate(attrs.expires_at, :second)
      assert key.name == "OAuth: Claude"
      assert key.prefix =~ ~r/\A[0-9a-f]{8}\z/
      assert byte_size(key.secret_hash) == 32
    end

    test "cuts a long client name to the name limit", %{scope: scope} do
      attrs = grant_attrs(%{client_name: String.duplicate("x", 300)})
      assert {:ok, key} = Keys.create_oauth_key(scope, attrs, impersonated: false)
      assert String.length(key.name) <= 100
      assert String.starts_with?(key.name, "OAuth: xxx")
    end

    test "cuts a name of combining marks by code points too, the size of the column", %{
      scope: scope
    } do
      # 80 graphemes, 160 code points: "OAuth: " and the name together would be 167 code points.
      name = String.duplicate("a\u0301", 80)
      attrs = grant_attrs(%{client_name: name})

      assert {:ok, key} = Keys.create_oauth_key(scope, attrs, impersonated: false)
      assert key.name |> String.to_charlist() |> length() <= 160
      assert String.length(key.name) <= 100
      assert String.starts_with?(key.name, "OAuth: a\u0301")
      assert String.valid?(key.name)
    end

    test "writes no api.key_created entry", %{scope: scope} do
      assert {:ok, key} = Keys.create_oauth_key(scope, grant_attrs(), impersonated: false)
      assert entries("api.key_created", key.uuid) == []
    end

    test "asks the session: impersonated, or no answer, is refused", %{scope: scope} do
      assert {:error, :impersonated} =
               Keys.create_oauth_key(scope, grant_attrs(), impersonated: true)

      assert {:error, :impersonation_unknown} = Keys.create_oauth_key(scope, grant_attrs(), [])
      assert Repo.aggregate(from(k in Key, where: not is_nil(k.oauth_grant_uuid)), :count) == 0
    end

    test "refuses a person with neither api_personal_keys nor api" do
      {_user, _role, scope} = api_holder_without_personal()

      assert {:error, :forbidden} =
               Keys.create_oauth_key(scope, grant_attrs(), impersonated: false)
    end

    test "refuses scopes the owner cannot hold", %{scope: scope} do
      attrs = grant_attrs(%{scopes: [write_scope()]})
      assert {:error, :invalid_scopes} = Keys.create_oauth_key(scope, attrs, impersonated: false)
    end

    test "refuses a missing, past or too far expiry", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} =
               Keys.create_oauth_key(scope, grant_attrs(%{expires_at: nil}), impersonated: false)

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:error, %Ecto.Changeset{}} =
               Keys.create_oauth_key(scope, grant_attrs(%{expires_at: past}), impersonated: false)

      far = DateTime.add(DateTime.utc_now(), 400 * 86_400, :second)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Keys.create_oauth_key(scope, grant_attrs(%{expires_at: far}), impersonated: false)

      assert %{expires_at: [_ | _]} = errors_on(changeset)
    end

    test "refuses a service user without the personal right at the first guard" do
      service = service_user_with(["User"])

      assert {:error, :forbidden} =
               Keys.create_oauth_key(scope_of(service), grant_attrs(), impersonated: false)

      assert oauth_key_count() == 0
    end

    test "refuses a service user who does hold the personal right: the owner is a person" do
      {role, _} = role_with(["api_personal_keys", "media"])
      service = service_user_with([role.name])

      assert {:error, :owner_not_allowed} =
               Keys.create_oauth_key(scope_of(service), grant_attrs(), impersonated: false)

      assert oauth_key_count() == 0
    end

    test "refuses a person who has not confirmed their address while confirmation is required",
         %{scope: scope, user: user} do
      Repo.update_all(from(u in User, where: u.uuid == ^user.uuid), set: [confirmed_at: nil])

      assert {:error, :owner_inactive} =
               Keys.create_oauth_key(scope, grant_attrs(), impersonated: false)

      assert oauth_key_count() == 0
    end

    test "refuses a blocked person", %{scope: scope, user: user} do
      user |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      # The locked row says inactive: the answer `create_personal_key/3` gives too.
      assert {:error, :forbidden} =
               Keys.create_oauth_key(scope, grant_attrs(), impersonated: false)

      assert oauth_key_count() == 0
    end

    test "refuses an account that is a managed organization by the time the row is locked", %{
      scope: scope,
      user: user
    } do
      # The scope was built before the conversion, as in a consent that crosses it: the
      # lock re-reads the row and refuses (`lock_mint_users`), whatever the scope still says.
      Repo.update_all(from(u in User, where: u.uuid == ^user.uuid),
        set: [account_type: "organization", managed_by_members: true]
      )

      assert {:error, :forbidden} =
               Keys.create_oauth_key(scope, grant_attrs(), impersonated: false)

      assert oauth_key_count() == 0
    end

    test "one key per grant uuid", %{scope: scope} do
      attrs = grant_attrs()
      assert {:ok, _key} = Keys.create_oauth_key(scope, attrs, impersonated: false)

      assert {:error, %Ecto.Changeset{}} =
               Keys.create_oauth_key(scope, attrs, impersonated: false)
    end

    test "needs a real grant uuid", %{scope: scope} do
      assert {:error, :invalid_grant} =
               Keys.create_oauth_key(scope, grant_attrs(%{grant_uuid: "nope"}),
                 impersonated: false
               )

      assert {:error, :invalid_grant} =
               Keys.create_oauth_key(scope, Map.delete(grant_attrs(), :grant_uuid),
                 impersonated: false
               )
    end

    test "is no key at all for no scope", %{} do
      assert {:error, :forbidden} = Keys.create_oauth_key(nil, grant_attrs(), impersonated: false)
      assert {:error, :impersonation_unknown} = Keys.create_oauth_key(nil, grant_attrs(), [])
    end
  end

  describe "the hidden key stays out of every key listing and limit" do
    setup %{scope: scope} do
      %{seed: seed_grant!(scope)}
    end

    test "not in list_keys for an Owner, nor for the holder of api", %{seed: seed} do
      owner = owner_user()
      refute Enum.any?(Keys.list_keys(scope_of(owner)), &(&1.uuid == seed.key.uuid))

      {api_user, _role, api_scope} = api_holder(["media"])
      {:ok, _grant, key} = seed_for(api_user, api_scope)
      refute Enum.any?(Keys.list_keys(api_scope), &(&1.uuid == key.uuid))
    end

    test "not in list_personal_keys", %{seed: seed, scope: scope} do
      assert Keys.list_personal_keys(scope) == []
      assert Repo.get!(Key, seed.key.uuid).oauth_grant_uuid == seed.grant.uuid
    end

    test "does not use up api_personal_key_max_count", %{scope: scope} do
      put_setting("api_personal_key_max_count", 1)
      refute Keys.personal_keys_full?(scope)

      attrs = %{
        name: "mine",
        scopes: [read_scope()],
        expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
      }

      assert {:ok, _key, _token} = Keys.create_personal_key(scope, attrs, impersonated: false)
      assert Keys.personal_keys_full?(scope)

      assert {:error, :personal_key_limit} =
               Keys.create_personal_key(scope, attrs, impersonated: false)

      # And the other way: a full person can still connect an application.
      assert {:ok, _grant, _key} = seed_for_scope(scope)
    end
  end

  describe "the hidden key is not a key a person handles" do
    setup %{scope: scope} do
      %{seed: seed_grant!(scope)}
    end

    test "rotate/4 and update_scopes/3 refuse it, even for its owner and for an Owner", %{
      seed: seed,
      scope: scope
    } do
      key = Repo.get!(Key, seed.key.uuid)

      assert {:error, :oauth_key} = Keys.rotate(key, 0, scope, impersonated: false)
      assert {:error, :oauth_key} = Keys.update_scopes(key, [], scope)

      owner_scope = scope_of(owner_user())
      assert {:error, :oauth_key} = Keys.rotate(key, 0, owner_scope, impersonated: false)
      assert {:error, :oauth_key} = Keys.update_scopes(key, [], owner_scope)

      assert Repo.get!(Key, key.uuid).scopes == key.scopes
      assert Repo.aggregate(from(k in Key, where: k.user_uuid == ^key.user_uuid), :count) == 1
    end

    test "verify/2 never takes it for a pk_ key, whatever token is built for it", %{seed: seed} do
      # Make a token that would match its row, as if someone knew the secret.
      secret = :crypto.strong_rand_bytes(32)
      token = "pk_" <> seed.key.prefix <> "_" <> Base.url_encode64(secret, padding: false)

      Repo.update_all(from(k in Key, where: k.uuid == ^seed.key.uuid),
        set: [secret_hash: KeyToken.hash(secret)]
      )

      Keys.Cache.invalidate(seed.key.prefix)

      assert {:error, :invalid_token} = Keys.verify(token, nil)
    end
  end

  describe "revoking the hidden key ends its grant" do
    setup %{scope: scope, user: user} do
      %{seed: seed_grant!(scope), user: user}
    end

    test "answers {:ok, key} and ends the key, the grant and every token", %{
      seed: seed,
      user: user
    } do
      assert {:ok, %Key{} = revoked} = Keys.revoke(seed.key, user.uuid)
      assert %DateTime{} = revoked.revoked_at

      grant = Repo.get!(Grant, seed.grant.uuid)
      assert grant.revoked_at

      tokens = Repo.all(from(t in Token, where: t.grant_uuid == ^seed.grant.uuid))
      assert length(tokens) == 2
      assert Enum.all?(tokens, &(&1.revoked_at && &1.revoke_reason == "grant_revoked"))
    end

    test "writes oauth.grant_revoked only, once", %{seed: seed, user: user} do
      assert {:ok, first} = Keys.revoke(seed.key, user.uuid)
      assert {:ok, second} = Keys.revoke(first, user.uuid)
      assert second.revoked_at == first.revoked_at

      assert [entry] = entries("oauth.grant_revoked", seed.grant.uuid)
      assert entry.actor_uuid == user.uuid
      assert entry.permanent
      refute inspect(entry.metadata) =~ seed.access
      assert entries("api.key_revoked", seed.key.uuid) == []
    end

    test "forgets the key in the key cache once the revocation has committed", %{seed: seed} do
      key = Repo.get!(Key, seed.key.uuid)
      assert %Key{revoked_at: nil} = Keys.Cache.fetch(key.prefix, fn -> key end)

      assert {:ok, _} = Grants.revoke(seed.grant)

      # A cached row would be returned as it is; the loader runs only on a miss.
      assert :reloaded = Keys.Cache.fetch(key.prefix, fn -> :reloaded end)
    end

    test "Grants.revoke/2 is the same end, reached from the grant", %{seed: seed} do
      assert {:ok, %Grant{revoked_at: %DateTime{}}} = Grants.revoke(seed.grant, actor_uuid: nil)
      assert %DateTime{} = Repo.get!(Key, seed.key.uuid).revoked_at
      assert {:ok, _} = Grants.revoke(seed.grant.uuid)
      assert [_] = entries("oauth.grant_revoked", seed.grant.uuid)
    end

    test "a revoked token keeps its own reason", %{seed: seed} do
      Repo.update_all(from(t in Token, where: t.uuid == ^seed.refresh_row.uuid),
        set: [
          revoked_at: DateTime.truncate(DateTime.utc_now(), :second),
          revoke_reason: "retry_superseded"
        ]
      )

      assert {:ok, _} = Grants.revoke(seed.grant)
      assert Repo.get!(Token, seed.refresh_row.uuid).revoke_reason == "retry_superseded"
      assert Repo.get!(Token, seed.access_row.uuid).revoke_reason == "grant_revoked"
    end

    test "a key whose grant is gone (its client was deleted) is still revoked, never refused", %{
      seed: seed,
      user: user
    } do
      Repo.delete_all(from(c in PhoenixKit.API.OAuth.Client, where: c.uuid == ^seed.client.uuid))

      assert Repo.get(Grant, seed.grant.uuid) == nil
      assert Repo.get!(Key, seed.key.uuid).revoked_at == nil

      assert {:ok, %Key{revoked_at: %DateTime{}}} =
               Keys.revoke(Repo.get!(Key, seed.key.uuid), user.uuid)

      assert %DateTime{} = Repo.get!(Key, seed.key.uuid).revoked_at
    end

    test "an unknown grant is not found", %{} do
      assert {:error, :not_found} = Grants.revoke(UUIDv7.generate())
      assert {:error, :not_found} = Grants.revoke("nope")
    end
  end

  describe "an account that holds a live grant becomes a managed organization" do
    test "the conversion succeeds and the grant ends with the rest of the credentials" do
      {actor, _admin} = F.admin_actor()
      manager = F.person()
      org = F.person(%{account_type: "organization", organization_name: "Independent"})
      role = F.role(["api_personal_keys", "media"], org)

      seed = seed_grant!(scope_of(Repo.get!(PhoenixKit.Users.Auth.User, org.uuid)))
      refute Repo.get!(Grant, seed.grant.uuid).revoked_at

      # A role with the right cannot be on a managed organization: it is taken off first.
      :ok = Permissions.revoke_permission(role.uuid, "api_personal_keys")

      assert {:ok, _managed} =
               ManagedOrganizations.convert_to_managed(actor, org.uuid, manager.uuid)

      assert Repo.get!(Grant, seed.grant.uuid).revoked_at
      assert Repo.get!(Key, seed.key.uuid).revoked_at

      assert Repo.all(
               from(t in Token, where: t.grant_uuid == ^seed.grant.uuid and is_nil(t.revoked_at))
             ) == []
    end
  end

  # An api holder that has neither `api` nor `api_personal_keys`.
  defp api_holder_without_personal do
    {user, role} = user_without_api(["media"])
    {user, role, scope_of(user)}
  end

  defp seed_for(user, scope) do
    client = client!()

    attrs = %{
      scopes: [read_scope()],
      expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
    }

    _ = user
    Grants.create(scope, client, attrs, impersonated: false)
  end

  defp seed_for_scope(scope), do: seed_for(nil, scope)
end
