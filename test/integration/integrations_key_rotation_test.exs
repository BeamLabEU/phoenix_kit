defmodule PhoenixKit.Integration.KeyRotationTest do
  @moduledoc """
  Exercises `PhoenixKit.Integrations.KeyRotation` against real database rows
  — a fact-based check of whether changing the encryption key actually
  preserves saved integrations, or silently strands them.

  ## What "row locking (concurrent-write safety)" below does and doesn't prove

  It confirms, via `Ecto.Adapters.SQL.to_sql/3` on the exact query
  `KeyRotation.locked_rows_query/0` builds, that the row-fetch is genuinely
  `SELECT ... FOR UPDATE` — not merely claimed in a comment. It does NOT drive
  a genuine two-connection race (a second transaction actually blocking on
  the lock, then observing the rotated value once released): that needs two
  independently-committing connections coordinated around the lock, which
  is more infrastructure than a single-process ExUnit test naturally
  provides — the same call `PhoenixKit.Integration.RepairTest` makes for
  its own S18 concurrent-migration scenario (see that file's moduledoc).
  The SQL-fact check here is what makes the guarantee inspectable without
  that infrastructure: `FOR UPDATE` is a standard, well-defined Postgres
  primitive — once it's confirmed to be in the actual query, the blocking
  behavior it provides is a property of Postgres, not of this test suite.
  """
  use PhoenixKit.DataCase, async: false

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.KeyRotation
  alias PhoenixKit.Notifications.Push.WebPush
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Settings.Setting

  setup do
    original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
    original_flat = Application.get_env(:phoenix_kit, :secret_key_base)

    on_exit(fn ->
      restore_env(:integrations_encryption_key, original_dedicated)
      restore_env(:secret_key_base, original_flat)
    end)

    # Every test starts from the most common real scenario: no dedicated
    # key yet, everything encrypted under the legacy secret_key_base tier.
    Application.delete_env(:phoenix_kit, :integrations_encryption_key)
    Application.put_env(:phoenix_kit, :secret_key_base, "current-secret-under-test")

    :ok
  end

  defp seed_connection(provider, name, attrs) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)
    {:ok, _} = Integrations.save_setup(uuid, attrs)
    uuid
  end

  defp raw_value_json(uuid), do: Queries.get_setting_by_uuid(uuid).value_json

  defp corrupt_row!(uuid, plaintext_field, secret) do
    corrupted = Encryption.encrypt_fields_with_secret(%{"api_key" => plaintext_field}, secret)

    uuid
    |> Queries.get_setting_by_uuid()
    |> Setting.update_changeset(%{value_json: corrupted})
    |> Queries.update_setting()

    corrupted
  end

  # Writes a field's value verbatim, bypassing `Encryption.encrypt_fields/1`
  # entirely — simulates a row whose sensitive field was saved while
  # encryption was off (or predates the feature), i.e. genuinely plaintext
  # in `value_json`, not merely undecryptable ciphertext.
  defp write_plaintext_field!(uuid, field, value) do
    updated = Map.put(raw_value_json(uuid) || %{}, field, value)

    uuid
    |> Queries.get_setting_by_uuid()
    |> Setting.update_changeset(%{value_json: updated})
    |> Queries.update_setting()

    updated
  end

  # Same idea as `write_plaintext_field!/3`, for a restricted
  # `PhoenixKit.Settings` row's bare `value` string instead of an
  # integration's `value_json` map. `Ecto.Changeset.change/2` — NOT
  # `Setting.update_changeset/2` — is the point: the latter runs
  # `maybe_encrypt_restricted_value/1` on every `:value` change, which would
  # immediately re-encrypt whatever this writes and defeat the whole point
  # of simulating a row saved before the encryption feature existed.
  defp write_plaintext_setting_value!(key, value) do
    {:ok, _} = Settings.update_setting(key, "placeholder-overwritten-below")

    {:ok, _} =
      key
      |> Queries.get_setting_by_key()
      |> Ecto.Changeset.change(value: value)
      |> Queries.update_setting()

    :ok
  end

  describe "rotate/2 — real run" do
    test "re-encrypts every connection under the new secret; the old key can no longer read it" do
      uuid1 = seed_connection("openrouter", "one", %{"api_key" => "sk-one"})
      uuid2 = seed_connection("openrouter", "two", %{"api_key" => "sk-two"})

      before1 = raw_value_json(uuid1)
      assert String.starts_with?(before1["api_key"], "enc:v1:")

      assert {:ok, %{rotated: 2, dry_run: false}} =
               KeyRotation.rotate("brand-new-secret-well-over-min-length")

      after1 = raw_value_json(uuid1)
      after2 = raw_value_json(uuid2)

      # Ciphertext actually changed (new key, new random IV).
      refute after1["api_key"] == before1["api_key"]

      # The OLD key is still the active config (rotation never flips it) —
      # it must no longer be able to read the row. This is the exact
      # silent-corruption path the decrypt-failure fix guards, exercised
      # end to end through a real rotation.
      refute Map.has_key?(Encryption.decrypt_fields(after1), "api_key")

      # The NEW secret, once configured as the active key, round-trips —
      # proving rotation wrote something *usable*, not just something new.
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "brand-new-secret-well-over-min-length"
      )

      assert Encryption.decrypt_fields(after1)["api_key"] == "sk-one"
      assert Encryption.decrypt_fields(after2)["api_key"] == "sk-two"
    end

    test "a connection with no sensitive fields is scanned but not counted as rotated, and stays readable" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "empty")
      before_rotation = raw_value_json(uuid)

      # `rotated` counts rows that actually carry an encrypted field, not
      # every row scanned — a row with nothing to decrypt would otherwise
      # get a wasted `UPDATE` with byte-identical `value_json` and be
      # misreported as rotated.
      assert {:ok, %{rotated: 0}} = KeyRotation.rotate("brand-new-secret-well-over-min-length")

      assert raw_value_json(uuid) == before_rotation

      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "brand-new-secret-well-over-min-length"
      )

      assert {:ok, %{provider: "openrouter"}} =
               Integrations.get_integration_by_uuid(uuid, :system)
    end

    test "rotated counts only rows that actually carry an encrypted field, in a mixed set" do
      _empty_uuid = seed_connection("openrouter", "empty", %{})
      _with_key_uuid = seed_connection("openrouter", "with-key", %{"api_key" => "sk-live"})

      assert {:ok, %{rotated: 1}} = KeyRotation.rotate("brand-new-secret-well-over-min-length")
    end

    test "a row whose sensitive field is still PLAINTEXT gets encrypted, not skipped" do
      # The exact scenario rotation exists for on "first adoption": a row
      # written while encryption was off (or predating the feature) has a
      # genuine secret sitting in value_json with no `enc:v1:` prefix at
      # all. `has_sensitive_field?/1` must key off the DECRYPTED view
      # (which passes plaintext through unchanged), not off "does the raw
      # value already look encrypted" -- the latter would skip precisely
      # the rows a first rotation is meant to protect.
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "plaintext")
      write_plaintext_field!(uuid, "api_key", "sk-plaintext-secret")

      before_rotation = raw_value_json(uuid)
      refute String.starts_with?(before_rotation["api_key"], "enc:v1:")

      assert {:ok, %{rotated: 1, dry_run: false}} =
               KeyRotation.rotate("brand-new-secret-well-over-min-length")

      after_rotation = raw_value_json(uuid)
      assert String.starts_with?(after_rotation["api_key"], "enc:v1:")
      refute after_rotation["api_key"] == before_rotation["api_key"]

      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "brand-new-secret-well-over-min-length"
      )

      assert Encryption.decrypt_fields(after_rotation)["api_key"] == "sk-plaintext-secret"
    end

    test "aborts and writes NOTHING when any row fails to decrypt under the current key" do
      uuid_good = seed_connection("openrouter", "good", %{"api_key" => "sk-good"})
      uuid_bad = seed_connection("openrouter", "bad", %{"api_key" => "sk-bad"})

      before_good = raw_value_json(uuid_good)
      # Simulate `uuid_bad` already being encrypted under a DIFFERENT secret
      # than the one currently active — e.g. a prior partial/manual change.
      corrupted = corrupt_row!(uuid_bad, "sk-bad", "some-other-secret")

      assert {:error, {:decrypt_failed, failed_uuid, :decrypt_failed_under_current_key}} =
               KeyRotation.rotate("brand-new-secret-well-over-min-length")

      assert failed_uuid == uuid_bad

      # Nothing was written — not even the row that decrypted fine.
      assert raw_value_json(uuid_good) == before_good
      assert raw_value_json(uuid_bad) == corrupted
    end
  end

  describe "rotate/2 — restricted PhoenixKit.Settings values (S015)" do
    test "the site keeps its browser push identity across encryption key rotation" do
      assert {:ok, key} = WebPush.vapid_key()
      secret = "new-push-rotation-secret-well-over-min-length"
      assert {:ok, %{rotated: 1}} = KeyRotation.rotate(secret)
      Application.put_env(:phoenix_kit, :integrations_encryption_key, secret)
      assert {:ok, ^key} = WebPush.vapid_key()
    end

    test "a restricted setting shares the same key and rotates alongside integration connections" do
      [restricted_key | _] = Settings.restricted_setting_keys()
      {:ok, _} = Settings.update_setting(restricted_key, "top-secret-value")

      before_row = Queries.get_setting_by_key(restricted_key)
      assert String.starts_with?(before_row.value, "enc:v1:")

      assert {:ok, %{rotated: 1, dry_run: false}} =
               KeyRotation.rotate("brand-new-secret-well-over-min-length")

      after_row = Queries.get_setting_by_key(restricted_key)
      refute after_row.value == before_row.value
      assert String.starts_with?(after_row.value, "enc:v1:")

      # The OLD key can no longer read it.
      assert {:error, _} = Encryption.decrypt_value(after_row.value)

      # The NEW secret, once active, round-trips.
      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "brand-new-secret-well-over-min-length"
      )

      assert Encryption.decrypt_value(after_row.value) == {:ok, "top-secret-value"}
    end

    test "an integration connection AND a restricted setting both rotate in the same run" do
      conn_uuid = seed_connection("openrouter", "one", %{"api_key" => "sk-one"})
      [restricted_key | _] = Settings.restricted_setting_keys()
      {:ok, _} = Settings.update_setting(restricted_key, "another-secret")

      assert {:ok, %{rotated: 2, dry_run: false}} =
               KeyRotation.rotate("brand-new-secret-well-over-min-length")

      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "brand-new-secret-well-over-min-length"
      )

      assert Encryption.decrypt_fields(raw_value_json(conn_uuid))["api_key"] == "sk-one"

      restricted_row = Queries.get_setting_by_key(restricted_key)
      assert Encryption.decrypt_value(restricted_row.value) == {:ok, "another-secret"}
    end

    test "rotate_rows_query returns a restricted setting row even though its module is nil" do
      [restricted_key | _] = Settings.restricted_setting_keys()
      {:ok, _} = Settings.update_setting(restricted_key, "some-value")

      repo = PhoenixKit.RepoHelper.repo()
      rows = repo.all(KeyRotation.rotate_rows_query())

      matched = Enum.find(rows, &(&1.key == restricted_key))
      assert matched
      assert matched.module == nil
    end

    # Every other test in this describe block seeds via
    # `Settings.update_setting/2`, which is ITSELF the encrypting write path
    # (`Setting.maybe_encrypt_restricted_value/1`) — so none of them can
    # distinguish "rotation handles a restricted setting" from "rotation
    # handles a restricted setting that happens to already be encrypted".
    # The real-world row this exists to protect (`oauth_google_client_secret`
    # written before the encryption feature shipped, e.g. on hosts running a
    # pre-#759 core) is genuinely plaintext in `value` — never `enc:v1:` at
    # all. `has_sensitive_field?/1` and `decrypt_row/1` key off the
    # DECRYPTED view (`Encryption.decrypt_value/1` passes plaintext through
    # unchanged, tagged `:legacy` by `Settings.decrypt_restricted_value/1`),
    # not off "does the raw value already look encrypted" — this test is
    # what actually exercises that, instead of it being a claim in a
    # comment.
    test "a restricted setting still PLAINTEXT (predates the feature) gets encrypted, " <>
           "and the real OAuth-credential read path hands back the original secret" do
      key = "oauth_google_client_secret"
      write_plaintext_setting_value!(key, "sk-legacy-plaintext-secret")

      before_row = Queries.get_setting_by_key(key)
      refute String.starts_with?(before_row.value, "enc:v1:")

      assert {:ok, %{rotated: 1, dry_run: false}} =
               KeyRotation.rotate("brand-new-secret-well-over-min-length")

      after_row = Queries.get_setting_by_key(key)
      assert String.starts_with?(after_row.value, "enc:v1:")
      refute after_row.value == before_row.value

      Application.put_env(
        :phoenix_kit,
        :integrations_encryption_key,
        "brand-new-secret-well-over-min-length"
      )

      # Not just "decrypt_value returns the right string" — the actual
      # function `PhoenixKit.Users.OAuthConfig.configure_providers/0` calls
      # to build the live Ueberauth `client_secret:` for Google. If this
      # returned the ciphertext, an empty string, or nil, OAuth login would
      # be broken by the fix, not protected by it.
      assert Settings.get_oauth_credentials_direct(:google).client_secret ==
               "sk-legacy-plaintext-secret"

      # Same guarantee through the plain single-key read path every other
      # caller of a restricted setting uses.
      assert Settings.get_setting(key) == "sk-legacy-plaintext-secret"
    end
  end

  describe "rotate/2 — dry_run" do
    test "reports the count without writing anything" do
      uuid = seed_connection("openrouter", "one", %{"api_key" => "sk-one"})
      before = raw_value_json(uuid)

      assert {:ok, %{rotated: 1, dry_run: true}} = KeyRotation.rotate("unused", dry_run: true)

      assert raw_value_json(uuid) == before
    end

    test "surfaces the same decrypt failure a real run would, without writing" do
      uuid = seed_connection("openrouter", "one", %{"api_key" => "sk-one"})
      corrupt_row!(uuid, "sk-one", "some-other-secret")

      assert {:error, {:decrypt_failed, ^uuid, :decrypt_failed_under_current_key}} =
               KeyRotation.rotate("unused", dry_run: true)
    end
  end

  describe "row locking (concurrent-write safety) — what it does and does not prove" do
    test "the real-rotation row-fetch query is a genuine SELECT ... FOR UPDATE" do
      {sql, _params} =
        EctoSQL.to_sql(
          :all,
          PhoenixKit.RepoHelper.repo(),
          KeyRotation.locked_rows_query()
        )

      assert sql =~ "FOR UPDATE"
    end

    test "the dry-run row-fetch query takes NO lock — a dry run must never block a live writer" do
      {sql, _params} =
        EctoSQL.to_sql(
          :all,
          PhoenixKit.RepoHelper.repo(),
          KeyRotation.rotate_rows_query()
        )

      refute sql =~ "FOR UPDATE"
    end
  end

  describe "rotate/2 — encryption not active" do
    test "refuses to run when integration_encryption_enabled is false" do
      original = Application.get_env(:phoenix_kit, :integration_encryption_enabled)
      on_exit(fn -> restore_env(:integration_encryption_enabled, original) end)
      Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)

      assert {:error, {:encryption_disabled, :disabled_explicit}} =
               KeyRotation.rotate("some-secret")
    end

    test "refuses to run when no key resolves at all" do
      original_parent = Application.get_env(:phoenix_kit, :parent_module)
      on_exit(fn -> restore_env(:parent_module, original_parent) end)

      Application.delete_env(:phoenix_kit, :integrations_encryption_key)
      Application.delete_env(:phoenix_kit, :secret_key_base)
      Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)

      assert {:error, {:encryption_disabled, :disabled_no_key}} =
               KeyRotation.rotate("some-secret")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore_env(key, value), do: Application.put_env(:phoenix_kit, key, value)
end
