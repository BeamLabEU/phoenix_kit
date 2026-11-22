defmodule PhoenixKit.HandoffTest do
  @moduledoc """
  The handoff context: the token row (mint, the one-statement redeem and everything that must
  NOT burn it, prune), the module hooks' dispatch and the host allow-list.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Handoff
  alias PhoenixKit.Handoff.Token
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Test.HandoffResolver
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  @host "shop-de.test"

  defp sha(value), do: :crypto.hash(:sha256, value)

  defp attrs(nonce, overrides \\ %{}) do
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

    test "of several simultaneous redeems exactly one wins" do
      nonce = Handoff.new_secret()
      token = mint!(nonce)

      results =
        1..8
        |> Task.async_stream(fn _ -> Handoff.redeem(token, @host, nonce) end, timeout: 10_000)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == :error)) == 7
    end

    test "a deleted account takes its rows with it" do
      user = KeyTestSupport.register_user!()
      nonce = Handoff.new_secret()
      token = mint!(nonce, %{user_uuid: user.uuid})
      assert row(token).user_uuid == user.uuid

      Repo.delete!(user)
      assert :error = Handoff.redeem(token, @host, nonce)
      assert is_nil(row(token))
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

  describe "carried_user/1 and eligible_user?/1" do
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

    test "only an active person is eligible" do
      assert Handoff.eligible_user?(user())
      refute Handoff.eligible_user?(user(is_active: false))
      refute Handoff.eligible_user?(nil)
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

    test "hands each module its own payload and the context, and collects notices and cookies" do
      payload = %{
        "notices" => %{"n" => 2},
        "map_result" => %{"x" => 1},
        "not_registered" => %{"y" => 1}
      }

      effects = Handoff.apply_payload(@context, payload, [Notices, MapResult])

      assert effects.notices == ["Moved 2.", "shop-de.test"] ++ ["From the map."]

      assert effects.cookies == [{"cart", "id", [sign: true, max_age: 60]}]
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
end
