defmodule PhoenixKit.HandoffTest do
  @moduledoc """
  The handoff context: the token row (mint, the one-statement redeem and everything that must
  NOT burn it, prune), the module hooks' dispatch and the host allow-list.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Cache
  alias PhoenixKit.Handoff
  alias PhoenixKit.Handoff.Token
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Test.HandoffDisabledModule
  alias PhoenixKit.Test.HandoffResolver
  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken

  @host "shop-de.test"

  # The hooks run in tasks of this supervisor (an application starts it; the suite does not).
  setup do
    unless Process.whereis(PhoenixKit.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})

    :ok
  end

  defp sha(value), do: :crypto.hash(:sha256, value)

  defp attrs(nonce, overrides) do
    Map.merge(
      %{
        target_host: @host,
        redirect_path: "/shop",
        browser_nonce_hash: sha(nonce),
        payload: %{"handoff_stub" => %{"cart" => "abc"}}
      },
      overrides
    )
  end

  defp mint!(nonce, overrides \\ %{}) do
    assert {:ok, token} = Handoff.mint(attrs(nonce, overrides))
    token
  end

  defp row(token), do: Repo.get_by(Token, token_hash: sha(token))

  # What the controller hands `mint/1` for a signed-in account: the account, and the session it
  # is signed in with.
  defp signed_in(user) do
    token = Auth.generate_user_session_token(user)
    %{uuid: uuid} = Auth.get_session_token_record(token)
    %{user_uuid: user.uuid, source_session_uuid: uuid}
  end

  defp age_session(uuid, seconds) do
    at = DateTime.add(DateTime.utc_now(), -seconds, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(t in UserToken, where: t.uuid == ^uuid), set: [inserted_at: at])
    at
  end

  describe "mint/1" do
    test "returns a 43-character token and stores only its hash" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)

      assert Handoff.secret?(token)
      assert %Token{} = stored = row(token)
      assert stored.token_hash == sha(token)
      refute stored.token_hash == token
      assert stored.target_host == @host
      assert stored.redirect_path == "/shop"
      assert stored.browser_nonce_hash == sha(nonce)
      assert stored.payload == %{"handoff_stub" => %{"cart" => "abc"}}
      assert is_nil(stored.used_at)
      assert is_nil(stored.user_agent_hash)

      ttl = DateTime.diff(stored.expires_at, stored.inserted_at)
      assert ttl in (Handoff.ttl_seconds() - 1)..(Handoff.ttl_seconds() + 1)
      assert Handoff.ttl_seconds() == 60
    end

    test "two mints are two different tokens" do
      nonce = Handoff.new_secret()
      refute mint!(nonce) == mint!(nonce)
    end

    test "stores the host without its port, lower-cased" do
      token = mint!(Handoff.new_secret(), %{target_host: "Shop-DE.test:8443"})
      assert row(token).target_host == @host
    end

    test "keeps a hash of the User-Agent, never the User-Agent" do
      token = mint!(Handoff.new_secret(), %{user_agent: "Mozilla/5.0 Test"})
      assert row(token).user_agent_hash == sha("Mozilla/5.0 Test")
    end

    test "refuses a path that is not local, and a nonce hash of the wrong size" do
      nonce = Handoff.new_secret()

      for path <- ["//evil.test", "https://evil.test/", "/\\evil", "/a\tb", "", nil] do
        assert {:error, :invalid_path} = Handoff.mint(attrs(nonce, %{redirect_path: path}))
      end

      assert {:error, :invalid_attrs} = Handoff.mint(attrs(nonce, %{browser_nonce_hash: "short"}))
      assert {:error, :invalid_attrs} = Handoff.mint(attrs(nonce, %{target_host: ""}))
      assert {:error, :invalid_attrs} = Handoff.mint(%{})
      assert Repo.aggregate(Token, :count) == 0
    end
  end

  describe "redeem/4" do
    test "consumes the row once and returns it" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)

      assert {:ok, %Token{} = redeemed} = Handoff.redeem(token, @host, nonce)
      assert redeemed.redirect_path == "/shop"
      assert redeemed.payload == %{"handoff_stub" => %{"cart" => "abc"}}
      assert %DateTime{} = redeemed.used_at
      assert %DateTime{} = row(token).used_at
    end

    test "a second redeem of the same token is refused" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)

      assert {:ok, _} = Handoff.redeem(token, @host, nonce)
      assert :error = Handoff.redeem(token, @host, nonce)
    end

    test "a wrong host is refused and does not burn the token" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)

      assert :error = Handoff.redeem(token, "shop-fr.test", nonce)
      assert is_nil(row(token).used_at)
      assert {:ok, _} = Handoff.redeem(token, @host, nonce)
    end

    test "the host compares case-insensitively" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)
      assert {:ok, _} = Handoff.redeem(token, "SHOP-DE.test", nonce)
    end

    test "a wrong nonce is refused and does not burn the token" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)

      assert :error = Handoff.redeem(token, @host, Handoff.new_secret())
      assert is_nil(row(token).used_at)
      assert {:ok, _} = Handoff.redeem(token, @host, nonce)
    end

    test "an expired token is refused, and an unknown one" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)

      past = DateTime.add(DateTime.utc_now(), -5, :second)

      Repo.update_all(from(t in Token, where: t.token_hash == ^sha(token)),
        set: [expires_at: past]
      )

      assert :error = Handoff.redeem(token, @host, nonce)
      assert is_nil(row(token).used_at)
      assert :error = Handoff.redeem(Handoff.new_secret(), @host, nonce)
    end

    test "a different User-Agent is refused and does not burn the token" do
      nonce = Handoff.new_secret()
      token = mint!(nonce, %{user_agent: "Browser A"})

      assert :error = Handoff.redeem(token, @host, nonce, user_agent: "Browser B")
      assert :error = Handoff.redeem(token, @host, nonce)
      assert is_nil(row(token).used_at)
      assert {:ok, _} = Handoff.redeem(token, @host, nonce, user_agent: "Browser A")
    end

    test "a row minted without a User-Agent does not look at the redeemer's" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)
      assert {:ok, _} = Handoff.redeem(token, @host, nonce, user_agent: "Anything")
    end

    test "input that is not a token, a host or a nonce is refused without a lookup" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)

      assert :error = Handoff.redeem("short", @host, nonce)
      assert :error = Handoff.redeem(token, @host, "short")
      assert :error = Handoff.redeem(token, @host, nil)
      assert :error = Handoff.redeem(token, "", nonce)
      assert :error = Handoff.redeem(token, nil, nonce)
      assert :error = Handoff.redeem(String.duplicate("\0", 43), @host, nonce)
      assert is_nil(row(token).used_at)
    end

    test "a deleted account takes its rows with it" do
      user = KeyTestSupport.register_user!()
      nonce = Handoff.new_secret()
      token = mint!(nonce, signed_in(user))
      assert row(token).user_uuid == user.uuid

      Repo.delete!(user)
      assert :error = Handoff.redeem(token, @host, nonce)
      assert is_nil(row(token))
    end
  end

  describe "the session a handoff continues" do
    setup do
      user = KeyTestSupport.register_user!()
      {:ok, user: user, nonce: Handoff.new_secret()}
    end

    test "mint stores the session's uuid, and a guest's row has none", %{user: user, nonce: nonce} do
      %{source_session_uuid: session} = attrs = signed_in(user)

      assert row(mint!(nonce, attrs)).source_session_uuid == session
      assert is_nil(row(mint!(nonce)).source_session_uuid)
    end

    test "an account cannot be carried without the session it is signed in with", %{
      user: user,
      nonce: nonce
    } do
      assert {:error, :invalid_attrs} =
               Handoff.mint(attrs(nonce, %{user_uuid: user.uuid}))

      for bad <- ["not-a-uuid", 7, ""] do
        assert {:error, :invalid_attrs} =
                 Handoff.mint(attrs(nonce, %{user_uuid: user.uuid, source_session_uuid: bad}))
      end

      assert Repo.all(Token) == []
    end

    test "redeem hands back the session, with the age and the role it acts as", %{
      user: user,
      nonce: nonce
    } do
      %{source_session_uuid: session} = attrs = signed_in(user)
      role = Ecto.UUID.generate()

      Repo.update_all(from(t in UserToken, where: t.uuid == ^session),
        set: [active_role_uuid: role]
      )

      aged = age_session(session, 7_200)
      token = mint!(nonce, attrs)

      assert {:ok, %Token{source_session: source}} = Handoff.redeem(token, @host, nonce)

      # Only what the new session takes over (and whose it is): no struct, no session token.
      assert source == %{user_uuid: user.uuid, inserted_at: aged, active_role_uuid: role}
      refute is_struct(source)
      refute Map.has_key?(source, :token)
    end

    test "a guest's row has no session to look up", %{nonce: nonce} do
      token = mint!(nonce)
      assert {:ok, %Token{source_session: nil}} = Handoff.redeem(token, @host, nonce)
    end

    test "a session revoked after the mint ends the handoff, without any revocation hook", %{
      user: user,
      nonce: nonce
    } do
      %{source_session_uuid: session} = attrs = signed_in(user)
      token = mint!(nonce, attrs)

      # A deletion that bypasses `Revocation` (and so `revoke_for_users/1`): the look-up at
      # redeem is the rule, whichever way the session went.
      {1, _} = Repo.delete_all(from(t in UserToken, where: t.uuid == ^session))

      assert :error = Handoff.redeem(token, @host, nonce)
    end

    test "a session that has expired since the mint ends it", %{user: user, nonce: nonce} do
      %{source_session_uuid: session} = attrs = signed_in(user)
      token = mint!(nonce, attrs)
      age_session(session, 61 * 86_400)

      assert :error = Handoff.redeem(token, @host, nonce)
    end

    test "a session just inside its 60 days still continues", %{user: user, nonce: nonce} do
      %{source_session_uuid: session} = attrs = signed_in(user)
      age_session(session, 60 * 86_400 - 3_600)

      assert {:ok, %Token{source_session: %{user_uuid: user_uuid}}} =
               Handoff.redeem(mint!(nonce, attrs), @host, nonce)

      assert user_uuid == user.uuid
    end

    test "a session of another account, or one that is not a session, is no session", %{
      user: user,
      nonce: nonce
    } do
      other = KeyTestSupport.register_user!()
      %{source_session_uuid: others_session} = signed_in(other)

      mine = mint!(nonce, %{user_uuid: user.uuid, source_session_uuid: others_session})
      assert :error = Handoff.redeem(mine, @host, nonce)

      {_raw, reset} = UserToken.build_email_token(user, "reset_password")
      reset = Repo.insert!(reset)

      not_a_session = mint!(nonce, %{user_uuid: user.uuid, source_session_uuid: reset.uuid})
      assert :error = Handoff.redeem(not_a_session, @host, nonce)
    end

    test "a row for an account that names no session is refused at redeem", %{
      user: user,
      nonce: nonce
    } do
      token = mint!(nonce, signed_in(user))

      Repo.update_all(from(t in Token, where: t.token_hash == ^sha(token)),
        set: [source_session_uuid: nil]
      )

      assert :error = Handoff.redeem(token, @host, nonce)
    end
  end

  describe "prune_expired/0" do
    test "deletes the rows that expired more than a day ago, and only those" do
      nonce = Handoff.new_secret()
      live = mint!(nonce)
      recent = mint!(nonce)
      stale = mint!(nonce)
      stale_used = mint!(nonce)

      set_expiry = fn token, seconds ->
        at = DateTime.add(DateTime.utc_now(), seconds, :second)

        Repo.update_all(from(t in Token, where: t.token_hash == ^sha(token)),
          set: [expires_at: at]
        )
      end

      set_expiry.(recent, -3600)
      set_expiry.(stale, -(86_400 + 60))
      set_expiry.(stale_used, -(2 * 86_400))

      assert Handoff.prune_expired() == 2
      assert row(live)
      assert row(recent)
      refute row(stale)
      refute row(stale_used)
      assert Handoff.prune_expired() == 0
    end
  end

  describe "secrets" do
    test "new_secret/0 is 32 random bytes in base64url, and secret?/1 knows its shape" do
      secret = Handoff.new_secret()
      assert byte_size(secret) == 43
      assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(secret, padding: false)
      refute secret == Handoff.new_secret()

      assert Handoff.secret?(secret)
      refute Handoff.secret?(secret <> "a")
      refute Handoff.secret?(String.duplicate("!", 43))
      refute Handoff.secret?(String.duplicate("a", 42))
      refute Handoff.secret?(nil)
    end

    test "the nonce hash parameter is the base64url SHA-256, and decodes back" do
      nonce = Handoff.new_secret()
      param = Handoff.nonce_hash_param(nonce)

      assert param == Base.url_encode64(sha(nonce), padding: false)
      assert {:ok, sha(nonce)} == Handoff.decode_nonce_hash(param)
      assert :error = Handoff.decode_nonce_hash("short")
      assert :error = Handoff.decode_nonce_hash(nil)
    end
  end

  describe "carried_user/1" do
    defp user(attrs \\ []) do
      struct(User, Keyword.merge([uuid: Ecto.UUID.generate(), email: "a@example.com"], attrs))
    end

    defp scope(user, attrs \\ []),
      do: struct(Scope, Keyword.merge([user: user, authenticated?: true], attrs))

    test "a visitor carries no account" do
      assert {:ok, nil} = Handoff.carried_user(%Scope{})
      assert {:ok, nil} = Handoff.carried_user(nil)
    end

    test "a signed-in account is carried" do
      account = user()
      assert {:ok, ^account} = Handoff.carried_user(scope(account))
    end

    test "an impersonated session, an acting one and an ineligible account are refused" do
      assert :refused = Handoff.carried_user(scope(user(), impersonated_by_uuid: "x"))
      assert :refused = Handoff.carried_user(scope(user(), acting_person: user()))
      assert :refused = Handoff.carried_user(scope(user(), acting_link: %{}))
      assert :refused = Handoff.carried_user(scope(user(acting_user_uuid: "x")))
      assert :refused = Handoff.carried_user(scope(user(is_active: false)))
      assert :refused = Handoff.carried_user(scope(user(api_only: true)))
      assert :refused = Handoff.carried_user(scope(user(managed_by_members: true)))
    end

    test "the account is refused exactly when Auth.sign_in_refusal/1 names a reason" do
      for {attrs, refusal} <- [
            {[], nil},
            {[is_active: false], :inactive},
            {[api_only: true], :not_independent},
            {[managed_by_members: true], :not_independent}
          ] do
        account = user(attrs)

        assert Auth.sign_in_refusal(account) == refusal
        assert Auth.may_sign_in?(account) == is_nil(refusal)
        assert Handoff.carried_user(scope(account)) == :refused == not is_nil(refusal)
      end

      refute Auth.may_sign_in?(nil)
    end
  end

  describe "hosts" do
    defmodule PortResolver do
      def host("de"), do: "shop-de.test:8443"
      def host("en"), do: "shop.test"
      def host(_), do: nil
    end

    defmodule OneHostResolver do
      def host(_language), do: "only.test"
    end

    defmodule RaisingResolver do
      def host(_language), do: raise("boom")
    end

    setup do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("de-DE")
      {:ok, _} = Languages.add_language("fr-FR")
      Application.put_env(:phoenix_kit, :canonical_host_resolver, {HandoffResolver, :host})
      on_exit(fn -> Application.delete_env(:phoenix_kit, :canonical_host_resolver) end)
    end

    test "the allow-list is what the resolver answers for the enabled languages" do
      assert Enum.sort(Handoff.allowed_hosts()) == ["shop-de.test", "shop-fr.test", "shop.test"]
      assert Handoff.enabled?()

      {:ok, _} = Languages.remove_language("fr-FR")
      assert Enum.sort(Handoff.allowed_hosts()) == ["shop-de.test", "shop.test"]
    end

    test "a host that is not on it is not allowed, whatever it looks like" do
      assert Handoff.allowed_host("shop-de.test") == "shop-de.test"
      assert Handoff.allowed_host("  SHOP-DE.test ") == "shop-de.test"

      for host <- [
            "evil.test",
            "shop-de.test.evil.test",
            "shop-de.test:99",
            "",
            " ",
            nil,
            5,
            [],
            String.duplicate("a", 300),
            "https://shop-de.test",
            "shop-de.test/"
          ] do
        assert Handoff.allowed_host(host) == nil
      end
    end

    test "own_host/1 finds the entry for a request host" do
      assert Handoff.own_host("shop.test") == "shop.test"
      assert Handoff.own_host("SHOP-FR.test") == "shop-fr.test"
      assert Handoff.own_host("www.example.com") == nil
    end

    test "a port belongs to the entry, not to the host name" do
      Application.put_env(:phoenix_kit, :canonical_host_resolver, {PortResolver, :host})

      assert Handoff.allowed_host("shop-de.test:8443") == "shop-de.test:8443"
      assert Handoff.allowed_host("shop-de.test") == nil
      assert Handoff.own_host("shop-de.test") == "shop-de.test:8443"
      assert Handoff.host_name("shop-de.test:8443") == "shop-de.test"
      assert Handoff.host_name("shop.test") == "shop.test"
    end

    test "language_for_host/1 names the language a host serves" do
      assert Handoff.language_for_host("shop-de.test") == "de-DE"
      assert Handoff.language_for_host("www.example.com") == nil
    end

    test "host_languages/0 emits each enabled language once and prefers exact dialect over base" do
      defmodule DialectAndBaseResolver do
        def host("de-DE"), do: "shop-de.test"
        def host("de"), do: "fallback-de.test"
        def host("en-US"), do: "shop.test"
        def host("en"), do: "shop.test"
        def host("fr"), do: "shop-fr.test"
        def host(_), do: nil
      end

      Application.put_env(:phoenix_kit, :canonical_host_resolver, {DialectAndBaseResolver, :host})

      assert Handoff.host_languages() == [
               {"en-US", "shop.test"},
               {"de-DE", "shop-de.test"},
               {"fr-FR", "shop-fr.test"}
             ]

      refute "fallback-de.test" in Handoff.allowed_hosts()
    end

    test "host_for_language/2 resolves enabled dialect codes and bare base codes alike" do
      assert Handoff.host_for_language("de-DE") == "shop-de.test"
      assert Handoff.host_for_language("DE-de") == "shop-de.test"
      assert Handoff.host_for_language("de") == "shop-de.test"
      assert Handoff.host_for_language("de-AT") == nil
      assert Handoff.host_for_language("xx") == nil
      assert Handoff.host_for_language(nil) == nil

      # Dialect-only resolver: bare base code still resolves via the enabled dialect.
      defmodule DialectOnlyResolver do
        def host("en-US"), do: "shop.test"
        def host("de-DE"), do: "shop-de.test"
        def host(_), do: nil
      end

      Application.put_env(:phoenix_kit, :canonical_host_resolver, {DialectOnlyResolver, :host})
      assert Handoff.host_for_language("de") == "shop-de.test"
      assert Handoff.host_for_language("de-DE") == "shop-de.test"
    end

    test "start_path/2 is the start endpoint with the language and a local target" do
      path = Handoff.start_path("de", "/shop?a=1")
      assert path == "/phoenix_kit/handoff/start?lang=de&to=%2Fshop%3Fa%3D1"
      assert Handoff.start_path("de") == "/phoenix_kit/handoff/start?lang=de&to=%2F"
      assert Handoff.start_path("de", "//evil.test") == Handoff.start_path("de", "/")
      assert Handoff.start_path("de", "https://evil.test") == Handoff.start_path("de", "/")
    end

    test "with no resolver, or one host, a handoff is not enabled" do
      Application.delete_env(:phoenix_kit, :canonical_host_resolver)
      assert Handoff.allowed_hosts() == []
      refute Handoff.enabled?()

      Application.put_env(:phoenix_kit, :canonical_host_resolver, {OneHostResolver, :host})
      assert Handoff.allowed_hosts() == ["only.test"]
      refute Handoff.enabled?()
    end

    test "a resolver that raises is no host" do
      Application.put_env(:phoenix_kit, :canonical_host_resolver, {RaisingResolver, :host})
      capture_log(fn -> assert Handoff.allowed_hosts() == [] end)
    end
  end

  describe "snapshots/2" do
    defmodule Good do
      def module_key, do: "good"

      def handoff_snapshot(context),
        do: %{n: 1, context_keys: context |> Map.keys() |> Enum.sort()}
    end

    defmodule Empty do
      def module_key, do: "empty"
      def handoff_snapshot(_context), do: nil
    end

    defmodule EmptyMap do
      def module_key, do: "empty_map"
      def handoff_snapshot(_context), do: %{}
    end

    defmodule Raising do
      def module_key, do: "raising"
      def handoff_snapshot(_context), do: raise("secret-session-value")
    end

    defmodule Throwing do
      def module_key, do: "throwing"
      def handoff_snapshot(_context), do: throw(:secret)
    end

    defmodule Exiting do
      def module_key, do: "exiting"
      def handoff_snapshot(_context), do: exit(:secret)
    end

    defmodule NotJson do
      def module_key, do: "not_json"
      def handoff_snapshot(_context), do: %{pid: self()}
    end

    defmodule NotAMap do
      def module_key, do: "not_a_map"
      def handoff_snapshot(_context), do: [1, 2]
    end

    defmodule Huge do
      def module_key, do: "huge"
      def handoff_snapshot(_context), do: %{blob: String.duplicate("x", 70_000)}
    end

    defmodule NoHook do
      def module_key, do: "no_hook"
    end

    defmodule NoKey do
      def handoff_snapshot(_context), do: %{a: 1}
    end

    @context %{user_uuid: nil, session: %{"a" => 1}, cookies: %{}}

    test "collects the maps modules answer, under their keys, as the database returns them" do
      log =
        capture_log(fn ->
          snapshots =
            Handoff.snapshots(@context, [
              Good,
              Empty,
              EmptyMap,
              Raising,
              Throwing,
              Exiting,
              NotJson,
              NotAMap,
              Huge,
              NoHook,
              NoKey
            ])

          assert snapshots == %{
                   "good" => %{"n" => 1, "context_keys" => ["cookies", "session", "user_uuid"]}
                 }
        end)

      assert log =~ "handoff_snapshot of PhoenixKit.HandoffTest.Raising raised RuntimeError"
      assert log =~ "Throwing throw"
      assert log =~ "Exiting exit"
      assert log =~ "NotJson is not JSON-safe"
      assert log =~ "NotAMap answered something else"
      assert log =~ "Huge is too large"
      refute log =~ "secret-session-value"
    end

    test "nothing to carry is an empty map" do
      assert Handoff.snapshots(@context, [Empty, EmptyMap, NoHook]) == %{}
      assert Handoff.snapshots(@context, []) == %{}
    end

    test "with no module list it asks the registered modules" do
      assert Handoff.snapshots(@context) == %{}
    end
  end

  describe "apply_payload/3" do
    defmodule Notices do
      def module_key, do: "notices"

      def handoff_apply(context, payload),
        do: {:ok, ["Moved #{payload["n"]}.", " ", 5, context.host]}
    end

    defmodule MapResult do
      def module_key, do: "map_result"

      def handoff_apply(_context, _payload) do
        {:ok,
         %{
           notices: ["From the map."],
           moved: 3,
           skipped: [1],
           cookies: [
             {"cart", "id", [sign: true, max_age: 60, domain: "evil.test", bogus: 1]},
             {"__Host-pk_handoff_nonce", "forged", []},
             {"bad", 5, []},
             :junk
           ]
         }}
      end
    end

    defmodule Failing do
      def module_key, do: "failing"
      def handoff_apply(_context, _payload), do: {:error, {:db, "secret-session-value"}}
    end

    defmodule ApplyRaising do
      def module_key, do: "raising"
      def handoff_apply(_context, _payload), do: raise("secret-session-value")
    end

    defmodule Strange do
      def module_key, do: "strange"
      def handoff_apply(_context, _payload), do: :ok
    end

    defmodule Chatty do
      def module_key, do: "chatty"
      def handoff_apply(_context, _payload), do: {:ok, Enum.map(1..9, &"Notice #{&1}")}
    end

    @context %{user_uuid: nil, session: %{}, cookies: %{}, host: "shop-de.test", locale: "de"}
    # Cookies are only accepted when the host's session cookie is named (see below).
    @session [session_cookies: ["_test_session"]]

    test "hands each module its own payload and the context, and collects notices and cookies" do
      payload = %{
        "notices" => %{"n" => 2},
        "map_result" => %{"x" => 1},
        "not_registered" => %{"y" => 1}
      }

      effects = Handoff.apply_payload(@context, payload, [Notices, MapResult], @session)

      assert effects.notices == ["Moved 2.", "shop-de.test"] ++ ["From the map."]

      assert [{"cart", "id", opts}] = effects.cookies

      assert Enum.sort(opts) == [
               http_only: true,
               max_age: 60,
               same_site: "Lax",
               secure: true,
               sign: true
             ]
    end

    test "a module with no entry in the payload is not called" do
      assert %{notices: [], cookies: []} =
               Handoff.apply_payload(@context, %{}, [Notices, ApplyRaising])
    end

    test "a failing module is logged and ignored, and the others still apply" do
      payload = %{"failing" => %{}, "raising" => %{}, "strange" => %{}, "notices" => %{"n" => 1}}

      log =
        capture_log(fn ->
          effects =
            Handoff.apply_payload(@context, payload, [Failing, ApplyRaising, Strange, Notices])

          assert effects.notices == ["Moved 1.", "shop-de.test"]
        end)

      assert log =~ "Failing returned an error"
      assert log =~ "ApplyRaising raised RuntimeError"
      assert log =~ "Strange answered something else"
      refute log =~ "secret-session-value"
    end

    test "at most five notices are kept" do
      effects = Handoff.apply_payload(@context, %{"chatty" => %{}}, [Chatty])
      assert length(effects.notices) == 5
    end
  end

  describe "mint/1 with nothing to carry" do
    test "refuses a handoff with no account and no payload, and writes no row" do
      nonce = Handoff.new_secret()

      for payload <- [nil, %{}] do
        assert {:error, :nothing_to_carry} =
                 Handoff.mint(attrs(nonce, %{payload: payload, user_uuid: nil}))
      end

      assert {:error, :nothing_to_carry} =
               Handoff.mint(Map.delete(attrs(nonce, %{user_uuid: nil}), :payload))

      assert Repo.all(Token) == []
    end

    test "an account alone is something to carry, and so is a payload alone" do
      user = KeyTestSupport.register_user!()
      nonce = Handoff.new_secret()

      assert {:ok, _} = Handoff.mint(attrs(nonce, Map.put(signed_in(user), :payload, %{})))
      assert {:ok, _} = Handoff.mint(attrs(nonce, %{user_uuid: nil}))
      assert length(Repo.all(Token)) == 2
    end
  end

  describe "retention" do
    defp expire(token, seconds_ago) do
      at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

      Repo.update_all(from(t in Token, where: t.token_hash == ^sha(token)),
        set: [expires_at: at]
      )
    end

    test "prune_expired/1 takes the age and the batch size" do
      nonce = Handoff.new_secret()
      tokens = for _ <- 1..5, do: mint!(nonce)
      for {token, age} <- Enum.zip(tokens, [60, 400, 400, 400, 400]), do: expire(token, age)

      # Nothing is that old by a day; four are by five minutes, the batch takes two.
      assert Handoff.prune_expired() == 0
      assert Handoff.prune_expired(older_than: 300, limit: 2) == 2
      assert Handoff.prune_expired(older_than: 300) == 2
      assert length(Repo.all(Token)) == 1
    end

    test "a mint deletes a small batch of rows that expired minutes ago, and keeps the rest" do
      nonce = Handoff.new_secret()
      stale = for _ <- 1..25, do: mint!(nonce)
      fresh = mint!(nonce)
      just_expired = mint!(nonce)

      for token <- stale, do: expire(token, 3_600)
      expire(just_expired, 30)
      assert length(Repo.all(Token)) == 27

      # This mint finds 25 that expired an hour ago and takes a batch of 20 of them.
      newest = mint!(nonce)

      remaining = Repo.all(Token)
      assert length(remaining) == 25 - 20 + 3
      assert row(fresh)
      assert row(just_expired)
      assert row(newest)
      assert Enum.count(stale, &row/1) == 5
    end
  end

  describe "mint/1 and the source proof" do
    test "a source proof hash is single use: the second mint with it is refused and writes nothing" do
      nonce = Handoff.new_secret()
      proof = sha(Handoff.new_secret())

      assert {:ok, token} = Handoff.mint(attrs(nonce, %{source_proof_hash: proof}))
      assert row(token).source_proof_hash == proof

      for _ <- 1..3 do
        assert {:error, :proof_used} = Handoff.mint(attrs(nonce, %{source_proof_hash: proof}))
      end

      assert Repo.aggregate(Token, :count) == 1
    end

    test "another proof, and a mint without one, are not affected" do
      nonce = Handoff.new_secret()

      assert {:ok, _} = Handoff.mint(attrs(nonce, %{source_proof_hash: sha("a")}))
      assert {:ok, _} = Handoff.mint(attrs(nonce, %{source_proof_hash: sha("b")}))
      assert {:ok, _} = Handoff.mint(attrs(nonce, %{}))
      assert {:ok, _} = Handoff.mint(attrs(nonce, %{}))
      assert Repo.aggregate(Token, :count) == 4
    end

    test "a proof hash that is not 32 bytes is refused" do
      assert {:error, :invalid_attrs} =
               Handoff.mint(attrs(Handoff.new_secret(), %{source_proof_hash: "short"}))

      assert Repo.aggregate(Token, :count) == 0
    end

    test "a refused mint (nothing to carry) does not spend the proof" do
      nonce = Handoff.new_secret()
      proof = sha("unspent")

      assert {:error, :nothing_to_carry} =
               Handoff.mint(attrs(nonce, %{source_proof_hash: proof, payload: %{}}))

      assert {:ok, _} = Handoff.mint(attrs(nonce, %{source_proof_hash: proof}))
    end

    test "decode_source_proof/1 reads the 32 bytes the s parameter names" do
      secret = Handoff.new_secret()
      param = Handoff.source_proof_param(secret)

      assert {:ok, sha(secret)} == Handoff.decode_source_proof(param)
      assert :error = Handoff.decode_source_proof("short")
      assert :error = Handoff.decode_source_proof(nil)
    end
  end

  describe "mint/1 and the caller's transaction" do
    test "a duplicate proof leaves a transaction of the caller's usable" do
      proof = sha("proof")
      nonce = Handoff.new_secret()
      mint!(nonce, %{source_proof_hash: proof})

      assert {:ok, :usable} =
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()

                 assert {:error, :proof_used} =
                          Handoff.mint(attrs(nonce, %{source_proof_hash: proof}))

                 # A unique violation aborts a transaction that has no savepoint to go back to.
                 assert %{rows: [[1]]} = Repo.query!("SELECT 1")
                 :usable
               end)
    end

    test "a mint that succeeds is the caller's: it is rolled back with the transaction" do
      nonce = Handoff.new_secret()

      assert {:error, token} =
               Repo.transaction(fn ->
                 assert {:ok, token} = Handoff.mint(attrs(nonce, %{}))
                 assert row(token)
                 Repo.rollback(token)
               end)

      refute row(token)
    end

    test "on a real connection with no transaction a duplicate proof is an answer, not a raise" do
      proof = sha("outside-#{System.unique_integer([:positive])}")
      nonce = Handoff.new_secret()

      try do
        Sandbox.unboxed_run(Repo, fn ->
          refute Repo.in_transaction?()
          assert {:ok, _} = Handoff.mint(attrs(nonce, %{source_proof_hash: proof}))

          assert {:error, :proof_used} =
                   Handoff.mint(attrs(nonce, %{source_proof_hash: proof}))
        end)
      after
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from(t in Token, where: t.source_proof_hash == ^proof))
        end)
      end
    end
  end

  describe "source_proof_used?/1" do
    test "is true for a proof that has a row, false for one that has none" do
      proof = sha("proof")
      nonce = Handoff.new_secret()

      refute Handoff.source_proof_used?(proof)
      mint!(nonce, %{source_proof_hash: proof})
      assert Handoff.source_proof_used?(proof)
      refute Handoff.source_proof_used?(sha("another"))
    end

    test "a proof that is not 32 bytes has no row" do
      refute Handoff.source_proof_used?("short")
      refute Handoff.source_proof_used?(nil)
    end

    test "stays true when the row has been used, and is what mint's unique index agrees with" do
      proof = sha("proof")
      nonce = Handoff.new_secret()
      token = mint!(nonce, %{source_proof_hash: proof})
      assert {:ok, _} = Handoff.redeem(token, @host, nonce)

      assert Handoff.source_proof_used?(proof)
      assert {:error, :proof_used} = Handoff.mint(attrs(nonce, %{source_proof_hash: proof}))
    end
  end

  describe "revoke_for_users/1" do
    test "deletes the unused handoffs of the accounts named, and nobody else's" do
      a = KeyTestSupport.register_user!()
      b = KeyTestSupport.register_user!()
      nonce = Handoff.new_secret()
      token_a = mint!(nonce, signed_in(a))
      used_a = mint!(nonce, signed_in(a))
      token_b = mint!(nonce, signed_in(b))
      guest = mint!(nonce)
      assert {:ok, _} = Handoff.redeem(used_a, @host, nonce)

      assert Handoff.revoke_for_users([a.uuid]) == 1

      refute row(token_a)
      assert row(used_a)
      assert row(token_b)
      assert row(guest)
      assert Handoff.revoke_for_users([]) == 0
    end
  end

  describe "the scheme" do
    setup do
      LanguageSettings.start_cache!()
      :ok
    end

    test "is https unless the site_url setting says http" do
      assert Handoff.scheme() == "https"

      Cache.put(:settings, "site_url", "http://shop.test")
      assert Handoff.scheme() == "http"

      Cache.put(:settings, "site_url", "https://shop.test")
      assert Handoff.scheme() == "https"

      Cache.put(:settings, "site_url", "ftp://shop.test")
      assert Handoff.scheme() == "https"
    end

    test "decides the names of the handoff cookies: __Host- only where it can be Secure" do
      assert Handoff.source_cookie("https") == "__Host-pk_handoff_src"
      assert Handoff.nonce_cookie("https") == "__Host-pk_handoff_nonce"
      assert Handoff.source_cookie("http") == "pk_handoff_src"
      assert Handoff.nonce_cookie("http") == "pk_handoff_nonce"

      assert Enum.sort(Handoff.cookie_names()) ==
               Enum.sort([
                 "__Host-pk_handoff_src",
                 "__Host-pk_handoff_nonce",
                 "pk_handoff_src",
                 "pk_handoff_nonce"
               ])
    end
  end

  describe "the source proof" do
    test "is the hash of the secret, and only that secret matches" do
      secret = Handoff.new_secret()
      proof = Handoff.source_proof_param(secret)

      assert Handoff.secret?(proof)
      assert Handoff.source_proof?(secret, proof)
      refute Handoff.source_proof?(Handoff.new_secret(), proof)
      refute Handoff.source_proof?(secret, Handoff.source_proof_param(Handoff.new_secret()))
      refute Handoff.source_proof?(nil, proof)
      refute Handoff.source_proof?(secret, nil)
      refute Handoff.source_proof?(secret, secret)
      refute Handoff.source_proof?("short", "short")
    end
  end

  describe "hook_context/4 and what a module is never handed" do
    test "drops the kit's session keys and cookies, and keeps the rest" do
      session =
        Map.new(Handoff.auth_session_keys(), &{&1, "secret"})
        |> Map.merge(%{"stub_cart" => "c1", "phoenix_flash" => %{}})

      cookies =
        Map.new(Handoff.auth_cookie_names(["_my_app_key"]), &{&1, "secret"})
        |> Map.merge(%{"stub_cart_id" => "c1", "theme" => "dark"})

      context = Handoff.hook_context("u1", session, cookies, session_cookies: ["_my_app_key"])

      assert context == %{
               user_uuid: "u1",
               session: %{"stub_cart" => "c1", "phoenix_flash" => %{}},
               cookies: %{"stub_cart_id" => "c1", "theme" => "dark"}
             }
    end

    test "the lists name what the kit really keeps in the session and in cookies" do
      assert Enum.sort(Handoff.auth_session_keys()) ==
               Enum.sort(~w(
                 user_token live_socket_id pk_session_accounts pk_own_tokens pk_impersonators
                 pk_organization_token phoenix_kit_session_uuid website_access_unlock
                 website_access_allowed _csrf_token
               ))

      names = Handoff.auth_cookie_names(["_my_app_key"])

      for name <- [
            "_phoenix_kit_web_user_remember_me",
            "_phoenix_kit_web_session_accounts",
            "_phoenix_kit_device",
            "pk_oauth_browser",
            "__Host-pk_handoff_src",
            "__Host-pk_handoff_nonce",
            "pk_handoff_src",
            "pk_handoff_nonce",
            "_my_app_key"
          ] do
        assert name in names, name
      end
    end

    test "the session cookie of an endpoint is read from its live socket" do
      assert Handoff.session_cookie_names(PhoenixKitWeb.Endpoint) == ["_phoenix_kit_key"]
      assert Handoff.session_cookie_names(nil) == []
      assert Handoff.session_cookie_names(String) == []
    end

    defmodule ListEndpoint do
      def __sockets__ do
        [
          {"/live", Phoenix.LiveView.Socket,
           [websocket: [connect_info: [session: [store: :cookie, key: "_list_key"]]]]}
        ]
      end
    end

    defmodule MfaEndpoint do
      def session, do: [store: :cookie, key: "_mfa_key"]

      def __sockets__ do
        [
          {"/live", Phoenix.LiveView.Socket,
           [websocket: [connect_info: [session: {__MODULE__, :session, []}]]]}
        ]
      end
    end

    defmodule BrokenMfaEndpoint do
      def __sockets__ do
        [
          {"/live", Phoenix.LiveView.Socket,
           [websocket: [connect_info: [session: {__MODULE__, :nope, []}]]]}
        ]
      end
    end

    defmodule NoSessionEndpoint do
      def __sockets__ do
        [{"/live", Phoenix.LiveView.Socket, [websocket: [connect_info: [:peer_data]]]}]
      end
    end

    test "a session declared as a list or as an {m, f, a} is read, and one that cannot be is not" do
      assert Handoff.session_cookie_names(ListEndpoint) == ["_list_key"]
      assert Handoff.session_cookie_names(MfaEndpoint) == ["_mfa_key"]

      capture_log(fn ->
        assert Handoff.session_cookie_names(BrokenMfaEndpoint) == []
        assert Handoff.session_cookie_names(NoSessionEndpoint) == []
      end)
    end

    defmodule SilentEndpoint do
      def __sockets__, do: []
    end

    test "an endpoint whose session cookie cannot be told is logged once, and only once" do
      log =
        capture_log(fn ->
          for _ <- 1..5, do: assert(Handoff.session_cookie_names(SilentEndpoint) == [])
        end)

      assert [_one] = Regex.scan(~r/session cookie of .*SilentEndpoint/, log)
      assert log =~ "no cookies"
    end

    test "with no session cookie name, a module is handed no cookies at all: it fails closed" do
      cookies = %{"_unknown_session" => "signed-session", "theme" => "dark"}

      for opts <- [[], [session_cookies: []]] do
        assert %{cookies: %{}, session: %{"stub_cart" => "c1"}, user_uuid: "u1"} ==
                 Handoff.hook_context("u1", %{"stub_cart" => "c1"}, cookies, opts)
      end

      assert %{cookies: %{"theme" => "dark"}} =
               Handoff.hook_context("u1", %{}, cookies, session_cookies: ["_unknown_session"])
    end

    test "the session keys of a header widget are the kit's, once, and no other list names them" do
      assert "phoenix_kit_session_uuid" in Handoff.auth_session_keys()

      assert PhoenixKit.HeaderWidget.reserved_session_keys() --
               Handoff.auth_session_keys() == []
    end
  end

  describe "hooks run only for enabled modules" do
    setup do
      :ok = ModuleRegistry.register(HandoffDisabledModule)
      on_exit(fn -> ModuleRegistry.unregister(HandoffDisabledModule) end)
    end

    test "a disabled module is registered, and is neither snapshotted nor applied" do
      assert HandoffDisabledModule in ModuleRegistry.all_modules()
      refute HandoffDisabledModule in ModuleRegistry.enabled_modules()

      context = %{user_uuid: nil, session: %{}, cookies: %{}}
      assert Handoff.snapshots(context) == %{}
      refute_received :disabled_snapshot_called

      payload = %{"handoff_disabled" => %{"secret" => "disabled"}}

      assert %{notices: [], cookies: []} =
               Handoff.apply_payload(Map.merge(context, %{host: "h", locale: nil}), payload)

      refute_received :disabled_apply_called
    end
  end

  describe "hooks run with a time limit" do
    defmodule SlowSnapshot do
      def module_key, do: "slow_snapshot"
      def handoff_snapshot(_context), do: Process.sleep(1_000) && %{a: 1}
    end

    defmodule SlowApply do
      def module_key, do: "slow_apply"
      def handoff_apply(_context, _payload), do: Process.sleep(1_000) && {:ok, ["late"]}
    end

    defmodule Quick do
      def module_key, do: "quick"
      def handoff_snapshot(_context), do: %{a: 1}
      def handoff_apply(_context, _payload), do: {:ok, ["on time"]}
    end

    defmodule Modest do
      def module_key, do: "modest"
      def handoff_snapshot(_context), do: Process.sleep(300) && %{a: 1}
      def handoff_apply(_context, _payload), do: Process.sleep(300) && {:ok, ["modest"]}
    end

    defmodule ReadsTheDatabase do
      def module_key, do: "reads_db"

      def handoff_snapshot(_context),
        do: %{users: Repo.aggregate(User, :count)}
    end

    @context %{user_uuid: nil, session: %{}, cookies: %{}, host: "h", locale: nil}

    test "a snapshot that takes too long is left out, the others are kept" do
      log =
        capture_log(fn ->
          assert Handoff.snapshots(@context, [SlowSnapshot, Quick], timeout: 50) == %{
                   "quick" => %{"a" => 1}
                 }
        end)

      assert log =~ "handoff_snapshot of PhoenixKit.HandoffTest.SlowSnapshot timed out"
    end

    test "an apply that takes too long is ignored, the others still apply" do
      payload = %{"slow_apply" => %{}, "quick" => %{}}

      log =
        capture_log(fn ->
          effects = Handoff.apply_payload(@context, payload, [SlowApply, Quick], timeout: 50)
          assert effects.notices == ["on time"]
        end)

      assert log =~ "handoff_apply of PhoenixKit.HandoffTest.SlowApply timed out"
    end

    test "the default limits leave a module that takes a third of a second alone" do
      assert Handoff.snapshots(@context, [Modest]) == %{"modest" => %{"a" => 1}}

      assert %{notices: ["modest"]} =
               Handoff.apply_payload(@context, %{"modest" => %{}}, [Modest])
    end

    for i <- 1..4 do
      defmodule Module.concat(__MODULE__, "Nap#{i}") do
        def module_key, do: unquote("nap_#{i}")
        def handoff_snapshot(_context), do: Process.sleep(250) && %{n: unquote(i)}

        def handoff_apply(_context, _payload),
          do: Process.sleep(250) && {:ok, [unquote("nap #{i}")]}
      end

      defmodule Module.concat(__MODULE__, "Hang#{i}") do
        def module_key, do: unquote("hang_#{i}")
        def handoff_snapshot(_context), do: Process.sleep(5_000) && %{n: unquote(i)}
        def handoff_apply(_context, _payload), do: Process.sleep(5_000) && {:ok, ["never"]}
      end
    end

    defp naps, do: for(i <- 1..4, do: Module.concat(__MODULE__, "Nap#{i}"))
    defp hangs, do: for(i <- 1..4, do: Module.concat(__MODULE__, "Hang#{i}"))
    defp elapsed_ms(fun), do: div(elem(:timer.tc(fun), 0), 1_000)

    test "modules run at the same time: four that take a quarter second each do not add up" do
      {ms, snapshots} = :timer.tc(fn -> Handoff.snapshots(@context, naps(), timeout: 2_000) end)

      assert Map.keys(snapshots) |> Enum.sort() == ["nap_1", "nap_2", "nap_3", "nap_4"]
      assert div(ms, 1_000) < 700, "snapshots took #{div(ms, 1_000)} ms: one after another"

      payload = Map.new(1..4, &{"nap_#{&1}", %{}})

      {ms, effects} =
        :timer.tc(fn -> Handoff.apply_payload(@context, payload, naps(), timeout: 2_000) end)

      # The order of the modules, not of who finished first.
      assert effects.notices == ["nap 1", "nap 2", "nap 3", "nap 4"]
      assert div(ms, 1_000) < 700, "applies took #{div(ms, 1_000)} ms: one after another"
    end

    test "one deadline covers the whole call: four modules that hang cost one timeout, not four" do
      log =
        capture_log(fn ->
          ms =
            elapsed_ms(fn ->
              assert Handoff.snapshots(@context, hangs(), timeout: 200) == %{}
            end)

          assert ms < 600, "four hung snapshots took #{ms} ms: the deadline is per module"

          ms =
            elapsed_ms(fn ->
              payload = Map.new(1..4, &{"hang_#{&1}", %{}})

              assert %{notices: [], cookies: []} =
                       Handoff.apply_payload(@context, payload, hangs(), timeout: 200)
            end)

          assert ms < 600, "four hung applies took #{ms} ms: the deadline is per module"
        end)

      for i <- 1..4 do
        assert log =~ "handoff_snapshot of PhoenixKit.HandoffTest.Hang#{i} timed out"
        assert log =~ "handoff_apply of PhoenixKit.HandoffTest.Hang#{i} timed out"
      end
    end

    test "a module that misses the deadline is killed, and the ones that made it are kept" do
      defmodule Straggler do
        def module_key, do: "straggler"

        def handoff_snapshot(_context) do
          send(List.first(Process.get(:"$callers")), {:straggler, self()})
          Process.sleep(5_000)
          %{late: true}
        end
      end

      capture_log(fn ->
        assert Handoff.snapshots(@context, [Straggler, Quick], timeout: 100) == %{
                 "quick" => %{"a" => 1}
               }
      end)

      assert_received {:straggler, pid}
      ref = Process.monitor(pid)
      # Killed before the call returned, or killed since: either way it is dead, not sleeping.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}
      assert reason in [:killed, :noproc]
    end

    test "a hook can read the database from its task" do
      assert %{"reads_db" => %{"users" => count}} =
               Handoff.snapshots(@context, [ReadsTheDatabase])

      assert is_integer(count)
    end

    test "the hook sees both the global and web Gettext locales of the request that asked" do
      Gettext.put_locale("de")
      Gettext.put_locale(PhoenixKitWeb.Gettext, "fr")

      defmodule Locale do
        def module_key, do: "locale"

        def handoff_snapshot(_context) do
          %{
            global: Gettext.get_locale(),
            web: Gettext.get_locale(PhoenixKitWeb.Gettext)
          }
        end
      end

      assert Handoff.snapshots(@context, [Locale]) == %{
               "locale" => %{"global" => "de", "web" => "fr"}
             }
    end
  end

  describe "what a module's apply may set" do
    defmodule Scripted do
      def module_key, do: "scripted"

      def handoff_apply(_context, _payload),
        do: Application.get_env(:phoenix_kit, :handoff_unit_answer)
    end

    @context %{user_uuid: nil, session: %{}, cookies: %{}, host: "h", locale: nil}

    defp answer(value, opts \\ @session) do
      Application.put_env(:phoenix_kit, :handoff_unit_answer, value)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :handoff_unit_answer) end)

      capture_log(fn ->
        send(
          self(),
          {:effects, Handoff.apply_payload(@context, %{"scripted" => %{}}, [Scripted], opts)}
        )
      end)

      assert_received {:effects, effects}
      effects
    end

    test "a cookie name must be an RFC token of at most 64 bytes, and not one of the kit's" do
      bad = [
        "bad name;x",
        "bad name",
        "a;b",
        "a=b",
        "a,b",
        "",
        String.duplicate("a", 65),
        "naïve",
        "__Host-pk_handoff_src",
        "pk_handoff_nonce",
        "_phoenix_kit_web_user_remember_me",
        "_phoenix_kit_web_session_accounts"
      ]

      for name <- bad do
        assert %{cookies: []} = answer({:ok, %{cookies: [{name, "v", []}]}}), inspect(name)
      end

      assert %{cookies: [{"good-name_1.x", "v", _}]} =
               answer({:ok, %{cookies: [{"good-name_1.x", "v", []}]}})

      # The host's session cookie is reserved by the name it is given: a module that
      # tries it is left out, and its other cookies are not.
      assert %{cookies: [{"theme", "dark", _}]} =
               answer(
                 {:ok, %{cookies: [{"_my_app_key", "v", []}, {"theme", "dark", []}]}},
                 session_cookies: ["_my_app_key"]
               )
    end

    test "with no session cookie name, every cookie a module sets is refused" do
      cookies = [{"theme", "dark", []}, {"_my_app_key", "v", []}]

      for opts <- [[], [session_cookies: []]] do
        assert %{notices: ["Kept."], cookies: []} =
                 answer({:ok, %{notices: ["Kept."], cookies: cookies}}, opts)
      end
    end

    test "and that is logged once for the module, not once per handoff" do
      :persistent_term.erase({Handoff, :cookies_refused, Scripted})
      Application.put_env(:phoenix_kit, :handoff_unit_answer, {:ok, %{cookies: [{"a", "b", []}]}})
      on_exit(fn -> Application.delete_env(:phoenix_kit, :handoff_unit_answer) end)

      log =
        capture_log(fn ->
          for _ <- 1..4,
              do: Handoff.apply_payload(@context, %{"scripted" => %{}}, [Scripted], [])
        end)

      assert [_one] = Regex.scan(~r/session cookie/, log)
      assert log =~ "Scripted"
    end

    test "a module that sets no cookie is not logged for the missing session cookie name" do
      :persistent_term.erase({Handoff, :cookies_refused, Scripted})
      Application.put_env(:phoenix_kit, :handoff_unit_answer, {:ok, %{notices: ["Only this."]}})
      on_exit(fn -> Application.delete_env(:phoenix_kit, :handoff_unit_answer) end)

      log =
        capture_log(fn ->
          assert %{notices: ["Only this."], cookies: []} =
                   Handoff.apply_payload(@context, %{"scripted" => %{}}, [Scripted], [])
        end)

      refute log =~ "session cookie"
    end

    test "a cookie value must be a binary of sane size and cookie characters" do
      for value <- [
            String.duplicate("a", 2049),
            "has space",
            "semi;colon",
            "co,mma",
            "quo\"te",
            "back\\slash",
            "new\nline",
            "naïve",
            5,
            nil
          ] do
        assert %{cookies: []} = answer({:ok, %{cookies: [{"c", value, []}]}}), inspect(value)
      end

      big = String.duplicate("a", 2048)
      assert %{cookies: [{"c", ^big, _}]} = answer({:ok, %{cookies: [{"c", big, []}]}})
      assert %{cookies: [{"c", "", _}]} = answer({:ok, %{cookies: [{"c", "", []}]}})

      # A signed value is sent as what Plug makes of it, so any text of that size will do.
      assert %{cookies: [{"c", "has space; ok", _}]} =
               answer({:ok, %{cookies: [{"c", "has space; ok", [sign: true]}]}})
    end

    test "the options are a whitelist, with values checked" do
      assert %{cookies: [{"c", "v", opts}]} =
               answer(
                 {:ok, %{cookies: [{"c", "v", [domain: "evil.test", unsafe: true, max_age: 60]}]}}
               )

      assert Enum.sort(Keyword.keys(opts)) == [:http_only, :max_age, :same_site, :secure]

      for bad <- [
            [max_age: -1],
            [max_age: "60"],
            [max_age: 40_000_000],
            [http_only: "yes"],
            [secure: 1],
            [same_site: "lax"],
            [same_site: "Whatever"],
            [path: "no-slash"],
            [path: "/a;b"],
            [path: "/ space"],
            [sign: true, encrypt: true],
            [same_site: "None", secure: false],
            :not_a_keyword
          ] do
        assert %{cookies: []} = answer({:ok, %{cookies: [{"c", "v", bad}]}}), inspect(bad)
      end

      assert %{cookies: [{"c", "v", opts}]} =
               answer({:ok, %{cookies: [{"c", "v", [path: "/shop", same_site: "Strict"]}]}})

      assert opts[:path] == "/shop"
      assert opts[:same_site] == "Strict"
    end

    test "a cookie is Secure, HttpOnly and SameSite=Lax unless the module says otherwise" do
      assert %{cookies: [{_, _, opts}]} = answer({:ok, %{cookies: [{"c", "v", []}]}})
      assert opts[:secure] == true
      assert opts[:http_only] == true
      assert opts[:same_site] == "Lax"

      assert %{cookies: [{_, _, opts}]} =
               answer(
                 {:ok,
                  %{cookies: [{"c", "v", [secure: false, http_only: false, same_site: "Strict"]}]}}
               )

      assert {opts[:secure], opts[:http_only], opts[:same_site]} == {false, false, "Strict"}

      # On a plain-http site (dev, test) the default cannot be Secure, or the browser drops it.
      assert %{cookies: [{_, _, opts}]} =
               answer({:ok, %{cookies: [{"c", "v", []}]}}, [{:scheme, "http"} | @session])

      assert opts[:secure] == false
    end

    test "at most five cookies of one module, and ten in all" do
      many = for n <- 1..8, do: {"c#{n}", "v", []}
      assert %{cookies: cookies} = answer({:ok, %{cookies: many}})
      assert length(cookies) == 5
    end

    test "notices are capped by bytes: five at most, 600 in all, cut on a character boundary" do
      emoji = String.duplicate("😀", 300)
      assert %{notices: notices} = answer({:ok, List.duplicate(emoji, 5)})

      assert length(notices) <= 5
      assert notices |> Enum.map(&byte_size/1) |> Enum.sum() <= 600
      assert Enum.all?(notices, &String.valid?/1)
      assert Enum.all?(notices, &(byte_size(&1) <= 300))

      # A cut inside a three-byte character drops the character.
      text = "a" <> String.duplicate("€", 200)
      assert %{notices: [cut]} = answer({:ok, [text]})
      assert String.valid?(cut)
      assert byte_size(cut) == 298
      assert String.starts_with?(text, cut)

      # The total, across notices that are each small.
      lines = for n <- 1..5, do: String.duplicate("é", 100) <> "#{n}"
      assert %{notices: kept} = answer({:ok, lines})
      assert kept |> Enum.map(&byte_size/1) |> Enum.sum() <= 600
      assert Enum.all?(kept, &String.valid?/1)
    end

    test "notices that are not text are left out" do
      assert %{notices: ["fine"]} = answer({:ok, ["fine", <<255, 254>>, 5, nil, :atom, "   "]})
    end

    test "answers that are not what the contract says are ignored, not raised on" do
      for garbage <- [
            :ok,
            nil,
            5,
            "text",
            {:ok, 5},
            {:ok, nil},
            {:ok, "text"},
            {:ok, %{cookies: :nope, notices: :nope}},
            {:ok, %{cookies: [{"a", "b"}, :junk, {1, 2, 3}, {"a", "b", "opts"}], notices: %{}}},
            {:error, "secret-session-value"},
            {:weird, :tuple, :of, :four}
          ] do
        assert %{notices: [], cookies: []} = answer(garbage), inspect(garbage)
      end
    end
  end
end
