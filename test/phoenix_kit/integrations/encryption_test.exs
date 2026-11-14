# A store that fails its FIRST read and answers every one after it. Not
# contrived: `KeyStore.cached_read/0` deliberately memoises only successes, so a
# store on a mount that blips, or one being rewritten, behaves exactly like this
# — and every caller that re-reads gets a different answer than the one before.
defmodule PhoenixKit.Integrations.EncryptionTest.FlakyStore do
  @behaviour PhoenixKit.Integrations.KeyStore

  @secret "a-stored-secret-well-over-the-minimum"

  def secret, do: @secret

  @impl true
  def read(opts) do
    n = :counters.get(opts[:counter], 1)
    :counters.add(opts[:counter], 1, 1)

    if n == 0, do: {:error, {:flaky, "first read fails"}}, else: {:ok, @secret}
  end

  @impl true
  def write(_secret, _opts), do: :ok

  @impl true
  def preflight(_opts), do: :ok

  @impl true
  def describe(_opts), do: "/flaky/store.key"
end

# A host endpoint as `PhoenixKit.Config.get_parent_endpoint/0` finds it, whose
# running config can be switched between "not started" (Phoenix raises: the
# endpoint's ETS table does not exist yet) and "started" with a given secret.
defmodule PhoenixKitSkbHost.Endpoint do
  @running_key {__MODULE__, :running_secret}

  def url, do: "http://localhost"

  def config(:secret_key_base) do
    case :persistent_term.get(@running_key, :not_started) do
      :not_started ->
        raise ArgumentError, "the table identifier does not refer to an existing ETS table"

      secret ->
        secret
    end
  end

  def config(_key), do: nil

  def start(secret), do: :persistent_term.put(@running_key, secret)
  def stop, do: :persistent_term.erase(@running_key)
end

# A host endpoint that defines the deprecated `init/2` callback: Phoenix runs it
# at start and uses the config it returns, so its app env may not hold the
# secret it will run with.
defmodule PhoenixKitSkbInitHost.Endpoint do
  def url, do: "http://localhost"

  def config(:secret_key_base),
    do: raise(ArgumentError, "the table identifier does not refer to an existing ETS table")

  def config(_key), do: nil

  def init(_context, config), do: {:ok, Keyword.put(config, :secret_key_base, "from-init")}
end

defmodule PhoenixKit.Integrations.EncryptionTest do
  # async: false — the encryption_key/0 fallback tests mutate the global
  # `:phoenix_kit` app env (`:secret_key_base`, `:parent_module`), which
  # other concurrently-running async test files could observe mid-test.
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.KeyStore

  describe "encrypt_fields/1 and decrypt_fields/1" do
    test "round-trips sensitive fields" do
      data = %{
        "provider" => "google",
        "auth_type" => "oauth2",
        "client_id" => "my-client-id",
        "client_secret" => "super-secret",
        "access_token" => "ya29.token123",
        "refresh_token" => "1//refresh456",
        "status" => "connected"
      }

      encrypted = Encryption.encrypt_fields(data)

      if Encryption.enabled?() do
        # Sensitive fields should be encrypted
        assert encrypted["client_secret"] != "super-secret"
        assert encrypted["access_token"] != "ya29.token123"
        assert encrypted["refresh_token"] != "1//refresh456"

        # Non-sensitive fields should be unchanged
        assert encrypted["provider"] == "google"
        assert encrypted["client_id"] == "my-client-id"
        assert encrypted["status"] == "connected"

        # Decrypt should restore originals
        decrypted = Encryption.decrypt_fields(encrypted)
        assert decrypted["client_secret"] == "super-secret"
        assert decrypted["access_token"] == "ya29.token123"
        assert decrypted["refresh_token"] == "1//refresh456"
        assert decrypted["provider"] == "google"
      else
        # Without secret_key_base, encryption is a no-op
        assert encrypted == data
      end
    end

    test "handles nil and empty values without error" do
      data = %{
        "provider" => "openrouter",
        "api_key" => nil,
        "access_token" => "",
        "status" => "disconnected"
      }

      encrypted = Encryption.encrypt_fields(data)
      assert encrypted["api_key"] == nil
      assert encrypted["access_token"] == ""

      decrypted = Encryption.decrypt_fields(encrypted)
      assert decrypted["api_key"] == nil
      assert decrypted["access_token"] == ""
    end

    test "does not re-encrypt already encrypted values" do
      if Encryption.enabled?() do
        data = %{"api_key" => "sk-test-key"}

        encrypted = Encryption.encrypt_fields(data)
        double_encrypted = Encryption.encrypt_fields(encrypted)

        # Should be the same — not double-encrypted
        assert encrypted["api_key"] == double_encrypted["api_key"]

        # Should decrypt to original
        assert Encryption.decrypt_fields(double_encrypted)["api_key"] == "sk-test-key"
      end
    end

    test "leaves non-encrypted values as-is on decrypt (backwards compatibility)" do
      data = %{
        "api_key" => "plaintext-key",
        "provider" => "openrouter"
      }

      # Decrypting unencrypted data should return it unchanged
      decrypted = Encryption.decrypt_fields(data)
      assert decrypted["api_key"] == "plaintext-key"
      assert decrypted["provider"] == "openrouter"
    end

    test "handles all auth type sensitive fields" do
      data = %{
        "access_token" => "token1",
        "refresh_token" => "token2",
        "client_secret" => "secret1",
        "api_key" => "key1",
        "bot_token" => "bot1",
        "secret_key" => "secret2"
      }

      encrypted = Encryption.encrypt_fields(data)
      decrypted = Encryption.decrypt_fields(encrypted)

      for field <- Encryption.sensitive_fields() do
        assert decrypted[field] == data[field],
               "Field #{field} did not round-trip correctly"
      end
    end

    test "decrypt_fields handles non-map input" do
      assert Encryption.decrypt_fields(nil) == nil
      assert Encryption.decrypt_fields("string") == "string"
    end

    test "encrypts and round-trips the smtp password field" do
      # `secret_key_base` isn't set as a flat `:phoenix_kit` app env key in
      # core's own test config (only nested under `PhoenixKitWeb.Endpoint`),
      # so this stamps one directly to make the round-trip meaningful.
      original = Application.get_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-password-encryption")

      on_exit(fn ->
        if original,
          do: Application.put_env(:phoenix_kit, :secret_key_base, original),
          else: Application.delete_env(:phoenix_kit, :secret_key_base)
      end)

      assert Encryption.enabled?()

      encrypted = Encryption.encrypt_fields(%{"password" => "not-a-real-smtp-secret"})
      assert String.starts_with?(encrypted["password"], "enc:v1:")

      decrypted = Encryption.decrypt_fields(encrypted)
      assert decrypted["password"] == "not-a-real-smtp-secret"
    end
  end

  describe "encryption_key/0 fallback to host endpoint secret_key_base" do
    setup do
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)

      on_exit(fn ->
        restore_env(:secret_key_base, original_flat)
        restore_env(:parent_module, original_parent)
      end)

      :ok
    end

    test "flat key set takes precedence and is used" do
      Application.put_env(:phoenix_kit, :secret_key_base, "flat-secret-for-test")
      # Point parent_module somewhere that would resolve to a different,
      # real endpoint too — proves the flat key wins, not just that it's
      # present when no fallback is available.
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit)

      assert Encryption.enabled?()

      encrypted = Encryption.encrypt_fields(%{"api_key" => "plain"})
      assert Encryption.decrypt_fields(encrypted)["api_key"] == "plain"
    end

    test "falls back to the host endpoint's secret_key_base when the flat key is unset" do
      Application.delete_env(:phoenix_kit, :secret_key_base)
      # `PhoenixKitWeb.Endpoint` is core's own endpoint, started for the
      # test suite with a real `secret_key_base` — `parent_module: PhoenixKit`
      # resolves to it exactly like a host app's `parent_module` would
      # resolve to its own `MyAppWeb.Endpoint`.
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit)

      assert Encryption.enabled?()

      encrypted = Encryption.encrypt_fields(%{"api_key" => "plain"})
      assert String.starts_with?(encrypted["api_key"], "enc:v1:")
      assert Encryption.decrypt_fields(encrypted)["api_key"] == "plain"
    end

    test "returns nil (plaintext passthrough) when neither flat key nor endpoint is available" do
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      refute Encryption.enabled?()

      data = %{"api_key" => "plain"}
      flag_key = {Encryption, :plaintext_write_logged}
      :persistent_term.erase(flag_key)
      on_exit(fn -> :persistent_term.erase(flag_key) end)

      ExUnit.CaptureLog.capture_log(fn -> assert Encryption.encrypt_fields(data) == data end)
    end
  end

  describe "secret_key_base before the host endpoint has started" do
    import ExUnit.CaptureLog

    @host_app :phoenix_kit_skb_host
    @host_endpoint PhoenixKitSkbHost.Endpoint
    @no_key_flag {Encryption, :no_key_decrypt_logged}

    setup do
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)

      # A loaded (not started) application that owns the endpoint module, as
      # the host app is for its own endpoint.
      :ok =
        :application.load(
          {:application, @host_app,
           [
             description: ~c"skb host",
             vsn: ~c"0.0.0",
             modules: [@host_endpoint],
             registered: [],
             applications: [:kernel, :stdlib]
           ]}
        )

      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKitSkbHost)
      @host_endpoint.stop()
      :persistent_term.erase(@no_key_flag)

      on_exit(fn ->
        @host_endpoint.stop()
        :application.unload(@host_app)
        :persistent_term.erase(@no_key_flag)
        restore_env(:secret_key_base, original_flat)
        restore_env(:parent_module, original_parent)
      end)

      :ok
    end

    # Encrypts under the key derived from `secret`, the way a running app with
    # that secret_key_base would have written the row.
    defp written_under(secret, data) do
      Application.put_env(:phoenix_kit, :secret_key_base, secret)
      encrypted = Encryption.encrypt_fields(data)
      Application.delete_env(:phoenix_kit, :secret_key_base)
      assert String.starts_with?(encrypted["api_key"], "enc:v1:")
      encrypted
    end

    test "reads the endpoint's secret from the host app env while the endpoint is not running" do
      stored = written_under("host-endpoint-secret-for-this-test", %{"api_key" => "sk-valid"})

      Application.put_env(@host_app, @host_endpoint,
        secret_key_base: "host-endpoint-secret-for-this-test"
      )

      assert_raise ArgumentError, fn -> @host_endpoint.config(:secret_key_base) end
      assert Encryption.status() == :legacy_secret_key_base
      assert Encryption.decrypt_fields(stored)["api_key"] == "sk-valid"
      assert Encryption.decrypt_value(stored["api_key"]) == {:ok, "sk-valid"}
    end

    test "the app env is not used when the endpoint defines init/2" do
      app = :phoenix_kit_skb_init_host
      endpoint = PhoenixKitSkbInitHost.Endpoint

      :ok =
        :application.load(
          {:application, app,
           [
             description: ~c"skb init host",
             vsn: ~c"0.0.0",
             modules: [endpoint],
             registered: [],
             applications: [:kernel, :stdlib]
           ]}
        )

      on_exit(fn -> :application.unload(app) end)
      Application.put_env(app, endpoint, secret_key_base: "app-env-secret-init-may-replace")
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKitSkbInitHost)

      assert Encryption.status() == :disabled_no_key
    end

    test "a malformed :parent_module resolves no key instead of raising" do
      Application.put_env(:phoenix_kit, :parent_module, %{not: "a module"})

      assert Encryption.status() == :disabled_no_key
    end

    test "the running endpoint's secret wins over the app env once it has started" do
      stored = written_under("running-endpoint-secret", %{"api_key" => "sk-valid"})
      Application.put_env(@host_app, @host_endpoint, secret_key_base: "stale-app-env-secret")
      @host_endpoint.start("running-endpoint-secret")

      assert Encryption.decrypt_fields(stored)["api_key"] == "sk-valid"
    end

    test "an explicit config :phoenix_kit, :secret_key_base wins over the endpoint" do
      stored = written_under("explicit-phoenix-kit-secret", %{"api_key" => "sk-valid"})
      Application.put_env(@host_app, @host_endpoint, secret_key_base: "endpoint-app-env-secret")
      @host_endpoint.start("endpoint-running-secret")
      Application.put_env(:phoenix_kit, :secret_key_base, "explicit-phoenix-kit-secret")

      assert Encryption.decrypt_fields(stored)["api_key"] == "sk-valid"
    end

    test "no secret anywhere: an error naming the setting, never a key from a missing secret" do
      stored = written_under("the-secret-it-was-written-under", %{"api_key" => "sk-valid"})
      # Neither running nor configured; an empty explicit value is not a secret.
      Application.put_env(:phoenix_kit, :secret_key_base, "")

      assert Encryption.status() == :disabled_no_key

      log =
        capture_log(fn ->
          assert Encryption.decrypt_value(stored["api_key"]) == {:error, :encryption_unavailable}
        end)

      assert log =~ "config :phoenix_kit, secret_key_base"

      map_log =
        capture_log(fn ->
          assert {%{} = result, ["api_key"]} = Encryption.decrypt_fields_with_failures(stored)
          refute Map.has_key?(result, "api_key")
        end)

      assert map_log =~ "config :phoenix_kit, secret_key_base"
      refute map_log =~ "sk-valid"
    end

    test "the decrypt_value/1 remedy is logged once per VM, not per read" do
      stored = written_under("the-secret-it-was-written-under", %{"api_key" => "sk-valid"})

      log =
        capture_log(fn ->
          for _ <- 1..3, do: Encryption.decrypt_value(stored["api_key"])
        end)

      assert length(String.split(log, ":encryption_unavailable")) == 2
    end
  end

  describe "decrypt failure safety (active key does not match the encrypting key)" do
    import ExUnit.CaptureLog

    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

      on_exit(fn ->
        restore_env(:integrations_encryption_key, original_dedicated)
        restore_env(:secret_key_base, original_flat)
      end)

      :ok
    end

    test "an undecryptable field is dropped, never handed back as raw ciphertext" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted = Encryption.encrypt_fields(%{"api_key" => "sk-live-real-secret"})
      assert String.starts_with?(encrypted["api_key"], "enc:v1:")

      # Simulate a key change made without running the rotation task first —
      # exactly the condition that must trip this safety net.
      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      decrypted = Encryption.decrypt_fields(encrypted)

      # The field must be ABSENT, not the leftover "enc:v1:..." string — a
      # caller checking `data["api_key"]` for presence must see nothing,
      # not something that merely fails to work as a real credential.
      refute Map.has_key?(decrypted, "api_key")
    end

    test "logs the decrypt failure instead of failing silently" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted = Encryption.encrypt_fields(%{"api_key" => "sk-live-real-secret"})

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      log = capture_log(fn -> Encryption.decrypt_fields(encrypted) end)

      assert log =~ "Failed to decrypt field"
      assert log =~ "api_key"
    end

    test "a non-sensitive field is untouched when a sensitive field on the same row fails to decrypt" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted =
        Encryption.encrypt_fields(%{
          "api_key" => "will-become-unreadable",
          "provider" => "openrouter"
        })

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      decrypted = Encryption.decrypt_fields(encrypted)
      refute Map.has_key?(decrypted, "api_key")
      assert decrypted["provider"] == "openrouter"
    end

    test "a corrupted field's decrypt failure does not affect a sibling sensitive field still decryptable under the same key" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted =
        Encryption.encrypt_fields(%{
          "api_key" => "will-be-corrupted",
          "bot_token" => "stays-readable"
        })

      # The active key never changes in this test — only this ONE field's
      # stored bytes are damaged (truncated, breaking base64 decoding).
      # Proves a per-field decrypt failure doesn't cascade to a SENSITIVE
      # sibling field that decrypts fine under the same, still-active key —
      # the thing the old test's name promised and its body never checked.
      corrupted = Map.update!(encrypted, "api_key", &String.slice(&1, 0..-6//1))

      decrypted = Encryption.decrypt_fields(corrupted)
      refute Map.has_key?(decrypted, "api_key")
      assert decrypted["bot_token"] == "stays-readable"
    end
  end

  describe "decrypt_fields_with_failures/1 — the write-side companion" do
    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)

      on_exit(fn ->
        restore_env(:integrations_encryption_key, original_dedicated)
        restore_env(:secret_key_base, original_flat)
        restore_env(:parent_module, original_parent)
      end)

      :ok
    end

    test "reports a field that failed to decrypt by name, in addition to dropping it" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted = Encryption.encrypt_fields(%{"api_key" => "sk-live-real-secret"})

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      {decrypted, failed} = Encryption.decrypt_fields_with_failures(encrypted)

      refute Map.has_key?(decrypted, "api_key")
      assert failed == ["api_key"]
    end

    test "returns the same map decrypt_fields/1 would, with an empty failure list, when everything decrypts" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted =
        Encryption.encrypt_fields(%{"api_key" => "sk-live", "provider" => "openrouter"})

      {decrypted, failed} = Encryption.decrypt_fields_with_failures(encrypted)

      assert decrypted == Encryption.decrypt_fields(encrypted)
      assert failed == []
    end

    test "reports every field that failed, not just the first" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "key-A-for-this-test")

      encrypted =
        Encryption.encrypt_fields(%{
          "api_key" => "sk-live",
          "bot_token" => "bot-live"
        })

      Application.put_env(:phoenix_kit, :secret_key_base, "key-B-completely-different")

      {_decrypted, failed} = Encryption.decrypt_fields_with_failures(encrypted)

      assert Enum.sort(failed) == ["api_key", "bot_token"]
    end

    test "returns an empty failure list when encryption is disabled (nothing to fail)" do
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      refute Encryption.enabled?()

      data = %{"api_key" => "plain"}
      assert Encryption.decrypt_fields_with_failures(data) == {data, []}
    end
  end

  describe "dedicated key vs. legacy secret_key_base precedence" do
    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

      on_exit(fn ->
        restore_env(:integrations_encryption_key, original_dedicated)
        restore_env(:secret_key_base, original_flat)
      end)

      :ok
    end

    test "status/0 reports :dedicated when a dedicated key is configured, even with a legacy key present" do
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret")

      assert Encryption.status() == :dedicated
    end

    test "a value encrypted under the dedicated key does not decrypt once only the legacy key resolves" do
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret")

      encrypted = Encryption.encrypt_fields(%{"api_key" => "under-dedicated-key"})

      # The dedicated key is removed WITHOUT rotating first — the legacy tier
      # takes over, and it must not accidentally read a value it never wrote.
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      assert Encryption.status() == :legacy_secret_key_base

      decrypted = Encryption.decrypt_fields(encrypted)
      refute Map.has_key?(decrypted, "api_key")
    end

    test "round-trips correctly while the dedicated key stays configured" do
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      encrypted = Encryption.encrypt_fields(%{"api_key" => "plain"})
      assert String.starts_with?(encrypted["api_key"], "enc:v1:")
      assert Encryption.decrypt_fields(encrypted)["api_key"] == "plain"
    end

    test "a dedicated key shorter than the minimum length does not count as dedicated" do
      # Without a floor, a 1-character `integrations_encryption_key` reports
      # as the healthy `:dedicated` tier — false assurance. A too-short
      # dedicated key must fall through the same tier chain an absent one
      # would, not silently pass as "the real thing".
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "x")
      Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret")

      assert Encryption.status() == :legacy_secret_key_base
    end

    test "warn_if_insecure/0 tells an operator with a too-short key apart from one who set nothing" do
      import ExUnit.CaptureLog

      Application.put_env(:phoenix_kit, :integrations_encryption_key, "too-short")
      Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret")

      # Falls back to the legacy tier (same as an absent key would)...
      assert Encryption.status() == :legacy_secret_key_base

      log = capture_log(fn -> Encryption.warn_if_insecure() end)

      # ...but the operator who configured a key, just too short, must not
      # be told "no dedicated key is configured" — they configured one. Asserts
      # the invariant rather than a phrase: the wording now comes from one
      # source (`Encryption.key_advice/0`) and is expected to be edited there.
      assert log =~ "shorter than"
      assert log =~ "rejected"
      assert log =~ "not the same as none being configured"
      refute log =~ "no dedicated key is"
    end
  end

  describe "status/0 and warn_if_insecure/0" do
    import ExUnit.CaptureLog

    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_enabled = Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)

      on_exit(fn ->
        restore_env(:integrations_encryption_key, original_dedicated)
        restore_env(:secret_key_base, original_flat)
        restore_env(:integration_encryption_enabled, original_enabled)
        restore_env(:parent_module, original_parent)
      end)

      :ok
    end

    test ":disabled_explicit when integration_encryption_enabled is false, regardless of key availability" do
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "dedicated")
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      assert Encryption.status() == :disabled_explicit
    end

    test ":disabled_no_key when enabled but no key material resolves at all" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      assert Encryption.status() == :disabled_no_key
    end

    test ":disabled_no_key when the only configured key is too short and nothing else resolves" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "too-short")
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      assert Encryption.status() == :disabled_no_key

      log = capture_log(fn -> Encryption.warn_if_insecure() end)
      assert log =~ "shorter than"
      refute log =~ "no encryption key could be resolved"
    end

    test ":legacy_secret_key_base when only secret_key_base resolves" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "legacy")

      assert Encryption.status() == :legacy_secret_key_base
    end

    test ":dedicated when a dedicated key is configured" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)

      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      assert Encryption.status() == :dedicated
    end

    test "warn_if_insecure/0 logs nothing for the healthy :dedicated case" do
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "dedicated-secret-well-over-min-length"
      )

      log = capture_log(fn -> assert Encryption.warn_if_insecure() == :ok end)

      # "This check says nothing", not "the log is empty". `capture_log/1`
      # collects everything the VM emits during the call, including a Postgrex
      # reconnection attempt from an unrelated pool, so the stricter assertion
      # fails on timing rather than on behaviour — observed doing exactly that
      # in a full run, and passing in isolation three times over.
      refute log =~ "[PhoenixKit.Integrations]"
    end

    test "warn_if_insecure/0 warns about the legacy fallback" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, "legacy")

      log = capture_log(fn -> Encryption.warn_if_insecure() end)
      assert log =~ "secret_key_base"
    end

    test "warn_if_insecure/0 warns about plaintext storage when explicitly disabled" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      log = capture_log(fn -> Encryption.warn_if_insecure() end)
      assert log =~ "PLAINTEXT"
    end
  end

  describe "encrypt_fields_with_secret/2 (rotation primitive)" do
    setup do
      original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      on_exit(fn -> restore_env(:integrations_encryption_key, original_dedicated) end)
      :ok
    end

    test "encrypts under an explicit secret, independent of the configured key" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)

      encrypted =
        Encryption.encrypt_fields_with_secret(
          %{"api_key" => "value"},
          "explicit-secret-well-over-min-length"
        )

      assert String.starts_with?(encrypted["api_key"], "enc:v1:")

      # Once that same secret becomes the configured dedicated key, it decrypts.
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "explicit-secret-well-over-min-length"
      )

      assert Encryption.decrypt_fields(encrypted)["api_key"] == "value"
    end

    test "a value encrypted with one explicit secret does not decrypt under another" do
      encrypted = Encryption.encrypt_fields_with_secret(%{"api_key" => "value"}, "secret-one")

      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "secret-two-well-over-min-length"
      )

      refute Map.has_key?(Encryption.decrypt_fields(encrypted), "api_key")
    end
  end

  describe "sensitive_fields/0" do
    test "returns expected fields" do
      fields = Encryption.sensitive_fields()
      assert "access_token" in fields
      assert "refresh_token" in fields
      assert "client_secret" in fields
      assert "api_key" in fields
      assert "bot_token" in fields
      assert "secret_key" in fields
      assert "password" in fields
    end
  end

  describe "encrypt_value/1, decrypt_value/1 and encrypted?/1" do
    setup do
      # Same rationale as the "smtp password field" test above: stamp a flat
      # secret_key_base directly so encryption is deterministically enabled,
      # regardless of what core's own test config carries.
      original = Application.get_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-value-encryption")

      on_exit(fn ->
        if original,
          do: Application.put_env(:phoenix_kit, :secret_key_base, original),
          else: Application.delete_env(:phoenix_kit, :secret_key_base)
      end)

      :ok
    end

    test "round-trips a single value" do
      encrypted = Encryption.encrypt_value("s3-secret-key")

      assert encrypted != "s3-secret-key"
      assert String.starts_with?(encrypted, "enc:v1:")
      assert Encryption.encrypted?(encrypted)
      assert Encryption.decrypt_value(encrypted) == {:ok, "s3-secret-key"}
    end

    test "is idempotent — does not double-encrypt an already-encrypted value" do
      once = Encryption.encrypt_value("plaintext")
      twice = Encryption.encrypt_value(once)

      assert once == twice
      assert Encryption.decrypt_value(twice) == {:ok, "plaintext"}
    end

    test "nil and empty values pass through unchanged" do
      assert Encryption.encrypt_value(nil) == nil
      assert Encryption.encrypt_value("") == ""
      assert Encryption.decrypt_value(nil) == {:ok, nil}
      assert Encryption.decrypt_value("") == {:ok, ""}
    end

    test "decrypt_value passes through legacy plaintext (no enc:v1: prefix) unchanged" do
      assert Encryption.decrypt_value("legacy-plaintext-secret") ==
               {:ok, "legacy-plaintext-secret"}
    end

    test "encrypted?/1 detects the enc:v1: prefix" do
      refute Encryption.encrypted?("plaintext")
      refute Encryption.encrypted?(nil)
      assert Encryption.encrypted?(Encryption.encrypt_value("x"))
    end
  end

  describe "encrypt_value/1 and decrypt_value/1 when encryption is unavailable" do
    import ExUnit.CaptureLog

    @value_flag_key {Encryption, :plaintext_value_logged}
    @write_flag_key {Encryption, :plaintext_write_logged}

    setup do
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)
      original_flag = Application.get_env(:phoenix_kit, :integration_encryption_warn_on_boot)
      original_enabled = Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)
      Application.delete_env(:phoenix_kit, :integration_encryption_enabled)
      :persistent_term.erase(@value_flag_key)
      :persistent_term.erase(@write_flag_key)

      on_exit(fn ->
        restore_env(:secret_key_base, original_flat)
        restore_env(:parent_module, original_parent)
        restore_env(:integration_encryption_warn_on_boot, original_flag)
        restore_env(:integration_encryption_enabled, original_enabled)
        :persistent_term.erase(@value_flag_key)
        :persistent_term.erase(@write_flag_key)
      end)

      refute Encryption.enabled?()
      :ok
    end

    test "encrypt_value/1 returns the value unchanged and logs a warning naming the function, not the value" do
      log =
        capture_log(fn ->
          assert Encryption.encrypt_value("s3-secret-should-not-be-logged") ==
                   "s3-secret-should-not-be-logged"
        end)

      assert log =~ "encrypt_value/1"
      assert log =~ "no encryption key is in use"
      assert log =~ Encryption.key_report_message(Encryption.key_report())
      refute log =~ "s3-secret-should-not-be-logged"
    end

    test "encrypt_value/1 logs only once per VM" do
      first = capture_log(fn -> Encryption.encrypt_value("s3-secret-1") end)
      second = capture_log(fn -> Encryption.encrypt_value("s3-secret-2") end)

      assert first =~ "encrypt_value/1"
      refute second =~ "encrypt_value/1"
    end

    test "encrypt_value/1 is not silenced by an earlier plaintext encrypt_fields/1 write" do
      capture_log(fn -> Encryption.encrypt_fields(%{"api_key" => "plaintext-api-key"}) end)

      log = capture_log(fn -> Encryption.encrypt_value("s3-secret-must-not-be-logged") end)

      assert log =~ "encrypt_value/1"
      refute log =~ "s3-secret-must-not-be-logged"
    end

    test "encrypt_value/1: an explicit warn_on_boot: false silences it only when encryption is off" do
      Application.put_env(:phoenix_kit, :integration_encryption_warn_on_boot, false)

      assert Encryption.status() == :disabled_no_key
      assert capture_log(fn -> Encryption.encrypt_value("s3-secret") end) =~ "encrypt_value/1"

      :persistent_term.erase(@value_flag_key)
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      assert Encryption.status() == :disabled_explicit
      refute capture_log(fn -> Encryption.encrypt_value("s3-secret") end) =~ "encrypt_value/1"
    end

    test "decrypt_value/1 returns {:error, :encryption_unavailable} for an already-encrypted value — never the ciphertext or a fabricated plaintext" do
      # Shape of a real enc:v1: value — this test only needs the prefix to
      # be recognized as "encrypted", not a value that decrypts cleanly.
      still_prefixed = "enc:v1:" <> Base.encode64(:crypto.strong_rand_bytes(40))

      assert Encryption.decrypt_value(still_prefixed) == {:error, :encryption_unavailable}
    end

    test "decrypt_value/1 still passes through legacy plaintext (no prefix) even with no key" do
      assert Encryption.decrypt_value("legacy-plaintext-secret") ==
               {:ok, "legacy-plaintext-secret"}
    end
  end

  describe "encrypt_fields/1 when no key resolves" do
    import ExUnit.CaptureLog

    @flag_key {Encryption, :plaintext_write_logged}

    setup do
      original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
      original_parent = Application.get_env(:phoenix_kit, :parent_module)
      original_enabled = Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)
      :persistent_term.erase(@flag_key)

      on_exit(fn ->
        restore_env(:secret_key_base, original_flat)
        restore_env(:parent_module, original_parent)
        restore_env(:integration_encryption_enabled, original_enabled)
        :persistent_term.erase(@flag_key)
      end)

      refute Encryption.enabled?()
      :ok
    end

    test "logs a warning the first time it stores a credential as plaintext, never the value" do
      data = %{"api_key" => "plaintext-api-key-must-not-be-logged", "name" => "x"}

      log = capture_log(fn -> assert Encryption.encrypt_fields(data) == data end)

      assert log =~ "[PhoenixKit.Integrations]"
      assert log =~ "PLAINTEXT"
      refute log =~ "plaintext-api-key-must-not-be-logged"
    end

    test "logs only once per VM" do
      data = %{"api_key" => "plaintext-api-key-1234567890"}

      first = capture_log(fn -> Encryption.encrypt_fields(data) end)
      second = capture_log(fn -> Encryption.encrypt_fields(data) end)

      assert first =~ "PLAINTEXT"
      refute second =~ "PLAINTEXT"
    end

    test "stays silent when nothing sensitive would be stored in plaintext" do
      log =
        capture_log(fn ->
          Encryption.encrypt_fields(%{"name" => "x", "api_key" => "", "password" => nil})
          Encryption.encrypt_fields(%{"api_key" => "enc:v1:" <> Base.encode64("already")})
        end)

      refute log =~ "PLAINTEXT"
      # ...and those writes did not use up the one-time warning.
      assert capture_log(fn ->
               Encryption.encrypt_fields(%{"api_key" => "real-plaintext-key"})
             end) =~
               "PLAINTEXT"
    end

    test "also warns when encryption is switched off explicitly" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      log = capture_log(fn -> Encryption.encrypt_fields(%{"password" => "hunter2-hunter2"}) end)

      assert log =~ "PLAINTEXT"
      refute log =~ "hunter2-hunter2"
    end

    test "an explicit warn_on_boot: false silences it when encryption is switched off" do
      original_flag = Application.get_env(:phoenix_kit, :integration_encryption_warn_on_boot)
      on_exit(fn -> restore_env(:integration_encryption_warn_on_boot, original_flag) end)
      Application.put_env(:phoenix_kit, :integration_encryption_warn_on_boot, false)
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      assert Encryption.status() == :disabled_explicit

      log = capture_log(fn -> Encryption.encrypt_fields(%{"password" => "hunter2-hunter2"}) end)

      refute log =~ "PLAINTEXT"
    end

    test "an explicit warn_on_boot: false does not silence it when no key resolves" do
      original_flag = Application.get_env(:phoenix_kit, :integration_encryption_warn_on_boot)
      on_exit(fn -> restore_env(:integration_encryption_warn_on_boot, original_flag) end)
      Application.put_env(:phoenix_kit, :integration_encryption_warn_on_boot, false)

      assert Encryption.status() == :disabled_no_key

      log = capture_log(fn -> Encryption.encrypt_fields(%{"password" => "hunter2-hunter2"}) end)

      assert log =~ "PLAINTEXT"
      refute log =~ "hunter2-hunter2"
    end

    test "does not warn when a key resolves" do
      Application.put_env(:phoenix_kit, :secret_key_base, "some-usable-secret-key-base-value")

      log = capture_log(fn -> Encryption.encrypt_fields(%{"api_key" => "k-1234567890"}) end)

      refute log =~ "PLAINTEXT"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore_env(key, value), do: Application.put_env(:phoenix_kit, key, value)

  describe "an unreadable key store is reported consistently" do
    # The per-read error and the boot warning are emitted by different functions
    # at different moments. They went out of step once already: the boot warning
    # was made tier-aware and the per-read error stayed blind, so a single run
    # could claim both "fell back to the secret_key_base key" and "no key at
    # all". They now share one source; these tests pin that they cannot diverge
    # again.
    setup do
      dir =
        Path.join(System.tmp_dir!(), "pk_store_consistency_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      path = Path.join(dir, "broken.key")
      File.write!(path, "")

      previous_store = Application.get_env(:phoenix_kit, :integrations_key_store)
      previous_skb = Application.get_env(:phoenix_kit, :secret_key_base)
      previous_parent = Application.get_env(:phoenix_kit, :parent_module)

      Application.put_env(
        :phoenix_kit,
        :integrations_key_store,
        {KeyStore.File, path: path}
      )

      on_exit(fn ->
        File.rm_rf(dir)

        restore = fn key, value ->
          if is_nil(value),
            do: Application.delete_env(:phoenix_kit, key),
            else: Application.put_env(:phoenix_kit, key, value)
        end

        restore.(:integrations_key_store, previous_store)
        restore.(:secret_key_base, previous_skb)
        restore.(:parent_module, previous_parent)
        KeyStore.invalidate_cache()
      end)

      # The per-read error is deliberately once-per-VM; clear the latch so each
      # test observes it. White-box on purpose — the alternative is a test that
      # silently passes because the message was already emitted.
      :persistent_term.erase({Encryption, :store_failure_logged})
      KeyStore.invalidate_cache()

      {:ok, path: path}
    end

    defp both_messages do
      import ExUnit.CaptureLog

      capture_log(fn ->
        Encryption.decrypt_fields(%{"api_key" => "enc:v1:not-real"})
        Encryption.warn_if_insecure()
      end)
    end

    test "with a legacy secret, both messages say a fallback happened" do
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("z", 64))

      log = both_messages()

      # Two surfaces, one run: the per-read error and the boot warning. Both
      # must describe the same reality — the assertion is about agreement, not
      # about a sentence, so unifying the wording cannot silently break it.
      assert log =~ "IS configured but its secret could not be read"
      assert log =~ "a key store is configured"
      assert log =~ "fell back to the secret_key_base-derived key"
      refute log =~ "PLAINTEXT"
    end

    test "with no key at all, both messages say PLAINTEXT and neither claims a fallback" do
      Application.put_env(:phoenix_kit, :secret_key_base, nil)
      Application.put_env(:phoenix_kit, :parent_module, nil)

      log = both_messages()

      assert log =~ "IS configured but its secret could not be read"
      assert log =~ "a key store is configured"
      assert log =~ "PLAINTEXT"
      refute log =~ "fell back to the secret_key_base-derived key"
    end
  end

  describe "key_fingerprint/0 makes key reuse between sites visible" do
    setup do
      previous_skb = Application.get_env(:phoenix_kit, :secret_key_base)
      previous_key = Application.get_env(:phoenix_kit, :integrations_encryption_key)
      # "no key at all" below also clears :parent_module; without restoring it
      # here the nil leaked into every test that ran afterwards, and anything
      # resolving the host endpoint (the sitemap's base-URL fallback) failed
      # depending on test order.
      previous_parent = Application.get_env(:phoenix_kit, :parent_module)

      on_exit(fn ->
        restore = fn key, value ->
          if is_nil(value),
            do: Application.delete_env(:phoenix_kit, key),
            else: Application.put_env(:phoenix_kit, key, value)
        end

        restore.(:secret_key_base, previous_skb)
        restore.(:integrations_encryption_key, previous_key)
        restore.(:parent_module, previous_parent)
      end)

      :ok
    end

    # The whole point of part 2. derive_key/1 is a plain hash of the secret, so
    # two installs that share a secret_key_base — copied from a template, cloned
    # from a sibling environment — hold a byte-identical integration key. This
    # is what lets an operator SEE that.
    test "two installs with the same secret produce the same fingerprint" do
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("s", 64))
      assert {:ok, first} = Encryption.key_fingerprint()

      # Simulate the second site: same secret, resolved from scratch.
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("s", 64))
      assert {:ok, ^first} = Encryption.key_fingerprint()
    end

    test "a different secret produces a different fingerprint" do
      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("s", 64))
      assert {:ok, first} = Encryption.key_fingerprint()

      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("t", 64))
      assert {:ok, second} = Encryption.key_fingerprint()

      refute first == second
    end

    # Discovered by writing this test with the opposite expectation. The key is
    # derived the same way whichever tier the secret came from, so copying your
    # secret_key_base into integrations_encryption_key does NOT change the key —
    # it only changes which config line it is read from. An operator doing that
    # believes they have migrated to a dedicated key; they have not, and every
    # site still sharing that secret_key_base still holds their key.
    #
    # The fingerprint says so out loud, which is the point of it.
    test "moving the SAME secret to the dedicated setting does not change the key" do
      secret = String.duplicate("u", 64)

      Application.put_env(:phoenix_kit, :secret_key_base, secret)
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      assert {:ok, legacy} = Encryption.key_fingerprint()

      Application.put_env(:phoenix_kit, :integrations_encryption_key, secret)
      assert {:ok, dedicated} = Encryption.key_fingerprint()

      assert legacy == dedicated
    end

    test "the fingerprint is short, hex, and is not the key" do
      secret = String.duplicate("v", 64)
      Application.put_env(:phoenix_kit, :integrations_encryption_key, secret)

      assert {:ok, fingerprint} = Encryption.key_fingerprint()
      assert String.length(fingerprint) == 12
      assert fingerprint =~ ~r/\A[0-9a-f]{12}\z/
      refute fingerprint =~ secret
      refute secret =~ fingerprint
    end

    test "no key at all → :none, so nothing is displayed to compare" do
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.put_env(:phoenix_kit, :secret_key_base, nil)
      Application.put_env(:phoenix_kit, :parent_module, nil)

      assert Encryption.key_fingerprint() == :none
    end
  end

  describe "key_diagnosis/0 is the one source both the warning and the doctor use" do
    setup do
      previous = %{
        skb: Application.get_env(:phoenix_kit, :secret_key_base),
        key: Application.get_env(:phoenix_kit, :integrations_encryption_key),
        store: Application.get_env(:phoenix_kit, :integrations_key_store),
        parent: Application.get_env(:phoenix_kit, :parent_module),
        enabled: Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      }

      on_exit(fn ->
        for {k, v} <- [
              secret_key_base: previous.skb,
              integrations_encryption_key: previous.key,
              integrations_key_store: previous.store,
              parent_module: previous.parent,
              integration_encryption_enabled: previous.enabled
            ] do
          if is_nil(v),
            do: Application.delete_env(:phoenix_kit, k),
            else: Application.put_env(:phoenix_kit, k, v)
        end

        KeyStore.invalidate_cache()
      end)

      Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("z", 64))
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.delete_env(:phoenix_kit, :integrations_key_store)
      KeyStore.invalidate_cache()
      :ok
    end

    test "a real dedicated key is :ok" do
      Application.put_env(:phoenix_kit, :integrations_encryption_key, String.duplicate("k", 40))
      assert {:dedicated, :ok} = Encryption.key_diagnosis()
    end

    # What every one of our sites is in today.
    test "no dedicated key at all is :no_dedicated_key" do
      assert {:legacy_secret_key_base, :no_dedicated_key} = Encryption.key_diagnosis()
    end

    # Must outrank :no_dedicated_key: the advice attached to that one sends the
    # operator to rotate, which would move the data off a key the store may
    # still be holding.
    test "an unreadable store outranks 'no dedicated key'" do
      dir = Path.join(System.tmp_dir!(), "pk_diag_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "broken.key")
      File.write!(path, "")
      on_exit(fn -> File.rm_rf(dir) end)

      Application.put_env(:phoenix_kit, :integrations_key_store, {KeyStore.File, path: path})
      KeyStore.invalidate_cache()

      assert {_status, :store_unreadable} = Encryption.key_diagnosis()
    end

    # "No dedicated key is configured" is a lie to someone who configured one.
    test "a configured-but-too-short key is :key_too_short, not 'none configured'" do
      Application.put_env(:phoenix_kit, :integrations_encryption_key, "short")
      assert {_status, :key_too_short} = Encryption.key_diagnosis()
    end

    test "encryption switched off explicitly is :turned_off" do
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)
      assert {:disabled_explicit, :turned_off} = Encryption.key_diagnosis()
    end

    test "no key material at all is :no_key_material" do
      Application.put_env(:phoenix_kit, :secret_key_base, nil)
      Application.put_env(:phoenix_kit, :parent_module, nil)
      assert {:disabled_no_key, :no_key_material} = Encryption.key_diagnosis()
    end
  end

  describe "key_signals/0 is one pass over the environment" do
    alias Mix.Tasks.PhoenixKit.Doctor, as: DoctorTask
    alias PhoenixKit.Integrations.EncryptionTest.FlakyStore
    alias PhoenixKitWeb.Live.Settings.Integrations, as: Page

    @legacy_secret String.duplicate("s", 64)

    setup do
      previous = %{
        skb: Application.get_env(:phoenix_kit, :secret_key_base),
        key: Application.get_env(:phoenix_kit, :integrations_encryption_key),
        store: Application.get_env(:phoenix_kit, :integrations_key_store),
        parent: Application.get_env(:phoenix_kit, :parent_module),
        enabled: Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      }

      on_exit(fn ->
        for {k, v} <- [
              secret_key_base: previous.skb,
              integrations_encryption_key: previous.key,
              integrations_key_store: previous.store,
              parent_module: previous.parent,
              integration_encryption_enabled: previous.enabled
            ] do
          if is_nil(v),
            do: Application.delete_env(:phoenix_kit, k),
            else: Application.put_env(:phoenix_kit, k, v)
        end

        KeyStore.invalidate_cache()
        :persistent_term.erase({Encryption, :store_failure_logged})
      end)

      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.put_env(:phoenix_kit, :secret_key_base, @legacy_secret)
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      KeyStore.invalidate_cache()
      :persistent_term.erase({Encryption, :store_failure_logged})
      :ok
    end

    # The defect this exists against, reproduced before the gather was made one
    # pass: the tier came from a failed read, the store state and the
    # fingerprint from a successful one, and the report printed the fingerprint
    # of the STORED key under the label "derived from secret_key_base". Two
    # operators comparing sites would have compared unlike keys while both pages
    # claimed the same tier — the exact failure the fingerprint exists to make
    # impossible.
    test "a store that answers one read and fails another cannot split the verdict" do
      counter = :counters.new(1, [])
      Application.put_env(:phoenix_kit, :integrations_key_store, {FlakyStore, counter: counter})
      KeyStore.invalidate_cache()

      signals = Encryption.key_signals()

      # Two reads, and exactly two: one resolution, and one look at what the
      # store holds right now. They answer different questions and only one of
      # them decides the key — the resolution's read is the memoised one the
      # running app encrypts with, and the second is deliberately fresh so the
      # verdict cannot describe a file from a value cached at boot. Three would
      # mean the gather went back to re-resolve, which is the defect this test
      # was written for.
      assert :counters.get(counter, 1) == 2,
             "key_signals/0 read the store #{:counters.get(counter, 1)} times; expected two"

      # Whatever it decided, the parts of it agree.
      assert signals.fingerprint == expected_fingerprint(signals)
    end

    # The historical bug itself, reproduced end to end rather than caught as a
    # side effect. Every assertion above works on the SIGNALS; the defect an
    # operator actually met was in the RENDERED line — a twelve-hex number
    # printed under a label naming a different key. Nothing rendered it in a
    # test, so reproducing it took hand assembly, and a suite that cannot
    # reproduce a bug cannot prove it stays fixed.
    #
    # The trigger is the real one: a store that fails a read and answers the
    # next. Before the gather became one pass this printed the fingerprint of
    # the STORED key under "derived from secret_key_base" — two sites comparing
    # those numbers would have compared unlike keys while both pages claimed the
    # same tier, which is precisely what the fingerprint exists to prevent.
    test "the printed fingerprint is the key its own label names" do
      counter = :counters.new(1, [])
      Application.put_env(:phoenix_kit, :integrations_key_store, {FlakyStore, counter: counter})
      KeyStore.invalidate_cache()

      report = Encryption.key_report()
      {_status, detail} = DoctorTask.integration_key_result(report, true)

      assert [_all, printed, label] =
               Regex.run(~r/Fingerprint ([0-9a-f]{12}) \(([^)]+)\)/, detail),
             "no fingerprint line to check in:\n#{detail}"

      assert printed == fingerprint_of(secret_named_by(label)),
             "the doctor printed #{printed} under #{inspect(label)}, which names a key whose " <>
               "fingerprint is #{fingerprint_of(secret_named_by(label))}"

      # The admin page labels the same number from the same report, in its own
      # translated words, and must name the same key.
      page_label = Page.fingerprint_tier(report)

      assert printed == fingerprint_of(secret_named_by(page_label)),
             "the admin page labelled #{printed} as #{inspect(page_label)}"
    end

    # Which key a label claims. Deliberately exhaustive with no catch-all: a new
    # label that this cannot classify must fail the test rather than pass it by
    # default, because an unclassifiable label is exactly how a number ends up
    # beside a tier nobody checked.
    defp secret_named_by(label) do
      cond do
        label =~ "secret_key_base" -> @legacy_secret
        label =~ "FALLBACK" -> @legacy_secret
        label =~ "dedicated" -> FlakyStore.secret()
      end
    end

    defp fingerprint_of(secret) do
      key = :crypto.hash(:sha256, "phoenix_kit_integrations:" <> secret)

      :sha256
      |> :crypto.pbkdf2_hmac(key, "phoenix_kit_integrations_fingerprint:v2", 100_000, 6)
      |> Base.encode16(case: :lower)
    end

    test "every signal in the map comes from the same reads, for either answer" do
      for first_read_fails? <- [true, false] do
        counter = :counters.new(1, [])
        # Burning the failing read first flips which answer the gather sees.
        unless first_read_fails?, do: :counters.add(counter, 1, 1)

        Application.put_env(:phoenix_kit, :integrations_key_store, {FlakyStore, counter: counter})
        KeyStore.invalidate_cache()
        :persistent_term.erase({Encryption, :store_failure_logged})

        signals = Encryption.key_signals()

        assert signals.fingerprint == expected_fingerprint(signals),
               "#{inspect(signals)}: the fingerprint is not the key the tier names"

        # A store answering with a usable secret IS a dedicated key source, so
        # the two cannot be seen apart within one gather.
        if match?({:holding, _}, signals.store) and signals.rejected_key == false do
          assert signals.tier == :dedicated,
                 "#{inspect(signals)}: a holding store beside a weaker tier"
        end
      end
    end

    # The fingerprint of the key the tier says is in use, derived independently
    # of the code under test.
    defp expected_fingerprint(%{enabled?: false}), do: :none
    defp expected_fingerprint(%{tier: :none}), do: :none

    defp expected_fingerprint(%{tier: tier}) do
      secret =
        case tier do
          :dedicated -> FlakyStore.secret()
          :legacy -> @legacy_secret
        end

      {:ok, fingerprint_of(secret)}
    end
  end

  describe "a shadowed store is not silent outside the :dedicated tier" do
    alias PhoenixKit.Integrations.EncryptionTest.FlakyStore
    alias PhoenixKitWeb.Live.Settings.Integrations, as: Page

    @legacy_secret String.duplicate("s", 64)

    setup do
      previous = %{
        skb: Application.get_env(:phoenix_kit, :secret_key_base),
        key: Application.get_env(:phoenix_kit, :integrations_encryption_key),
        store: Application.get_env(:phoenix_kit, :integrations_key_store),
        parent: Application.get_env(:phoenix_kit, :parent_module),
        enabled: Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      }

      on_exit(fn ->
        for {k, v} <- [
              secret_key_base: previous.skb,
              integrations_encryption_key: previous.key,
              integrations_key_store: previous.store,
              parent_module: previous.parent,
              integration_encryption_enabled: previous.enabled
            ] do
          if is_nil(v),
            do: Application.delete_env(:phoenix_kit, k),
            else: Application.put_env(:phoenix_kit, k, v)
        end

        KeyStore.invalidate_cache()
      end)

      Application.put_env(:phoenix_kit, :integration_encryption_enabled, true)
      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      # A real parent app's Endpoint has its own secret_key_base, which
      # `secret_key_base/0` falls back to once the flat config key is absent
      # — without pinning this to a nonexistent app, whether the :none-tier
      # test below sees `:none` or `:legacy` depends on which parent_module
      # an unrelated test left behind, not on this test's own setup.
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)
      :ok
    end

    # The window between a rotation and the restart it requires, reproduced
    # deterministically rather than raced: `key_signals/0` makes two reads of
    # the store per call — one memoised (decides the TIER), one deliberately
    # fresh (decides what the report SAYS the store holds), see its moduledoc.
    # `FlakyStore` fails its first read and succeeds every one after, so the
    # first (tier) read sees nothing usable while the second (display) read
    # — a moment later, same call — sees the secret a separate
    # `mix phoenix_kit.integrations.rotate_key` run just finished writing.
    # That is exactly what two independent OS processes (this one, and the
    # rotation) observe of the same durable store when a write lands between
    # the two reads — ordered by real events, not by a timing accident.
    test "tier: :legacy names the shadowing store instead of falling silent" do
      Application.put_env(:phoenix_kit, :secret_key_base, @legacy_secret)
      counter = :counters.new(1, [])
      Application.put_env(:phoenix_kit, :integrations_key_store, {FlakyStore, counter: counter})
      KeyStore.invalidate_cache()

      signals = Encryption.key_signals()
      assert signals.tier == :legacy
      assert signals.rejected_key == false
      assert match?({:shadowed, _}, signals.store)

      report = Encryption.key_report(signals)
      assert report.diagnosis == {:legacy_secret_key_base, :store_shadowed}
      assert report.severity == :warn
      refute report.rotation_safe?

      message = Encryption.key_report_message(report)
      assert message =~ "/flaky/store.key"

      title = Page.encryption_status_title(report)
      detail = Page.encryption_status_detail(report)

      refute title == Page.encryption_status_title({:no_such_status, :no_such_reason})
      refute detail == Page.encryption_status_detail({:no_such_status, :no_such_reason})
      assert detail =~ "/flaky/store.key"
    end

    # Same window, one tier weaker: no key resolves at all (no secret_key_base
    # either), yet the store already answers on the fresh read.
    test "tier: :none names the shadowing store instead of falling silent" do
      Application.delete_env(:phoenix_kit, :secret_key_base)
      counter = :counters.new(1, [])
      Application.put_env(:phoenix_kit, :integrations_key_store, {FlakyStore, counter: counter})
      KeyStore.invalidate_cache()

      signals = Encryption.key_signals()
      assert signals.tier == :none
      assert signals.rejected_key == false
      assert match?({:shadowed, _}, signals.store)

      report = Encryption.key_report(signals)
      assert report.diagnosis == {:disabled_no_key, :store_shadowed}
      assert report.severity == :fail
      refute report.rotation_safe?

      message = Encryption.key_report_message(report)
      assert message =~ "/flaky/store.key"
      assert message =~ "PLAINTEXT"

      title = Page.encryption_status_title(report)
      detail = Page.encryption_status_detail(report)

      refute title == Page.encryption_status_title({:no_such_status, :no_such_reason})
      refute detail == Page.encryption_status_detail({:no_such_status, :no_such_reason})
      assert detail =~ "/flaky/store.key"
    end
  end

  describe "the states the real resolution actually produces" do
    alias Mix.Tasks.PhoenixKit.Doctor, as: DoctorTask
    alias PhoenixKit.Test.KeyVerdictInvariants, as: Invariants

    setup do
      previous = %{
        skb: Application.get_env(:phoenix_kit, :secret_key_base),
        key: Application.get_env(:phoenix_kit, :integrations_encryption_key),
        store: Application.get_env(:phoenix_kit, :integrations_key_store),
        parent: Application.get_env(:phoenix_kit, :parent_module),
        enabled: Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      }

      dir = Path.join(System.tmp_dir!(), "pk_states_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn ->
        for {k, v} <- [
              secret_key_base: previous.skb,
              integrations_encryption_key: previous.key,
              integrations_key_store: previous.store,
              parent_module: previous.parent,
              integration_encryption_enabled: previous.enabled
            ] do
          if is_nil(v),
            do: Application.delete_env(:phoenix_kit, k),
            else: Application.put_env(:phoenix_kit, k, v)
        end

        KeyStore.invalidate_cache()
        :persistent_term.erase({Encryption, :store_failure_logged})
        File.rm_rf(dir)
      end)

      {:ok, dir: dir}
    end

    # Reachability is OBSERVED here, never argued — and, since round 6's
    # enumeration was found to be synthetic, the states are no longer written
    # down at all. `KeyVerdictInvariants.real_space/1` drives real
    # configurations — a config key that is absent, short or valid; a store that
    # is missing, empty, holds a short secret, holds another valid one, or holds
    # the config key itself; with and without secret_key_base; encryption on and
    # off — through the real `key_signals/0`, and this asserts on whatever comes
    # out.
    #
    # The difference is not academic. The hand-built space was green across 60
    # combinations while a real configuration — a short secret in the key store
    # with no `integrations_encryption_key` set — rendered advice naming a
    # variable the operator does not have. It contained a `{:holding, _}` store
    # because someone wrote one down, and no short stored secret because nobody
    # thought to. A cross product of our idea of the states cannot fail on an
    # idea that is wrong.
    test "every state the real resolution produces survives every invariant", %{dir: dir} do
      produced = Invariants.real_space(dir)

      assert length(produced) == 72

      for {label, signals} <- produced do
        Invariants.assert_consistent(signals, label)
      end
    end

    # The synthetic space is still worth having — it proves the verdict is total
    # — but only while it contains everything the system can actually do. Asserted
    # rather than assumed, so a real state with no synthetic twin fails here
    # instead of quietly narrowing what the other enumeration covers.
    test "nothing the real resolution produces is missing from the synthetic space",
         %{dir: dir} do
      synthetic = MapSet.new(Invariants.synthetic_space(), &Invariants.shape/1)

      for {label, signals} <- Invariants.real_space(dir) do
        assert MapSet.member?(synthetic, Invariants.shape(signals)),
               "#{label}: real signals #{inspect(signals)} are outside the synthetic space"
      end
    end

    # The states this feature exists for, named so that a fixture change cannot
    # quietly drop one. Each was a defect before it was a test.
    test "the real configurations reach the states the rounds were about", %{dir: dir} do
      shapes =
        dir
        |> Invariants.real_space()
        |> Enum.map(fn {_label, signals} ->
          {signals.tier, signals.rejected_key, Invariants.store_tag(signals.store)}
        end)
        |> Enum.uniq()

      # P012 round 2: a short secret in the store and no config key. The advice
      # named `integrations_encryption_key` here, which does not exist.
      assert {:legacy, :store, :shadowed} in shapes

      # P012: the store holds a secret that is not the key in use.
      assert {:dedicated, false, :shadowed} in shapes

      # Round 6: a configured store with nothing in it yet, which used to be
      # reported as holding the key.
      assert {:legacy, false, :no_secret_yet} in shapes

      # Round 5: a working dedicated key beside a store that cannot be read.
      assert {:dedicated, false, :unreadable} in shapes

      # The store as the key source, and the healthy baseline.
      assert {:dedicated, false, :holding} in shapes
      assert {:legacy, false, :absent} in shapes
      assert {:none, false, :absent} in shapes
    end

    # A diagnosis that survives its own remedy teaches people to ignore
    # diagnoses. The store's contents used to be read from the boot-time cache,
    # so an operator who did exactly what the advice said watched the warning
    # stay until a restart — and saw it clear in `mix phoenix_kit.doctor`, whose
    # VM is new, which makes it look like the page is wrong rather than stale.
    test "the warning goes out when the operator does what it says, without a restart",
         %{dir: dir} do
      path = Path.join(dir, "shadowed.key")
      config_key = String.duplicate("k", 40)

      File.write!(path, "SOMETHING-ELSE-well-over-the-minimum")
      File.chmod!(path, 0o600)

      put(:integrations_key_store, {KeyStore.File, path: path})
      put(:integrations_encryption_key, config_key)
      put(:secret_key_base, String.duplicate("s", 64))
      KeyStore.invalidate_cache()

      assert Encryption.key_diagnosis() == {:dedicated, :store_shadowed}

      # Exactly the remedy the advice gives, and nothing else: no restart, no
      # cache invalidation.
      File.write!(path, config_key)
      File.chmod!(path, 0o600)

      assert Encryption.key_diagnosis() == {:dedicated, :ok}
      assert match?({:holding, ^path}, Encryption.key_signals().store)
    end

    # The whole P012 chain as an operator meets it: the verdict, the severity
    # that decides whether the admin page says anything at all, and the line
    # that used to read as "your key is saved here".
    test "a store holding a different secret is named, warned about, and not called a backup",
         %{dir: dir} do
      path = Path.join(dir, "other.key")
      File.write!(path, "STORE-secret-well-over-the-minimum")
      File.chmod!(path, 0o600)

      put(:integrations_key_store, {KeyStore.File, path: path})
      put(:integrations_encryption_key, "CONFIG-secret-well-over-the-minimum")
      put(:secret_key_base, String.duplicate("s", 64))
      KeyStore.invalidate_cache()

      report = Encryption.key_report()
      {status, detail} = DoctorTask.integration_key_result(report, true)

      assert report.diagnosis == {:dedicated, :store_shadowed}

      # :ok would mean the admin page renders no banner — which is how this went
      # unmentioned on every surface until now.
      assert status == :warn
      refute report.rotation_safe?

      assert detail =~ "holds a different secret"
      assert detail =~ "DIFFERENT secret"
      assert detail =~ "Do NOT run"
      assert detail =~ path
    end

    defp put(key, value), do: Application.put_env(:phoenix_kit, key, value)
  end
end
