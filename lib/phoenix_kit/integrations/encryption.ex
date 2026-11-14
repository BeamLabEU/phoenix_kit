defmodule PhoenixKit.Integrations.Encryption do
  @moduledoc """
  AES-256-GCM encryption for sensitive integration credentials.

  Encrypts fields like `access_token`, `refresh_token`, `client_secret`,
  `api_key`, `bot_token`, `secret_key`, `password` before storing in the
  database. Decrypts them when reading.

  ## Key resolution

  The AES key is derived (SHA-256) from a secret, tried in this order:

    1. **Dedicated key** — `config :phoenix_kit, :integrations_encryption_key`.
       The recommended setup: a random secret independent of anything else
       in the app, generated with `mix phoenix_kit.integrations.rotate_key`
       and wired from an environment variable in `runtime.exs`, e.g.

           config :phoenix_kit,
             integrations_encryption_key: System.get_env("PHOENIX_KIT_INTEGRATIONS_ENCRYPTION_KEY")

    2. **Legacy fallback** — the application's `secret_key_base`, looked up
       in this order:

         * `config :phoenix_kit, :secret_key_base` — explicit, and available
           in every process from the moment config is loaded;
         * the host endpoint's running config (`MyAppWeb.Endpoint.config/1`,
           the endpoint found through `config :phoenix_kit, :parent_module`);
         * the same endpoint's entry in the host app's env
           (`config :my_app, MyAppWeb.Endpoint, secret_key_base: ...`), for
           code that runs before the endpoint has started or on a node that
           never starts it (`mix run --no-start`, a release `eval`, a job
           picked up at boot). Skipped when the endpoint defines the
           deprecated `init/2` callback, which may replace that secret at
           start.

       Setting the flat key to the value your Endpoint uses is the explicit
       way to pin it:

           config :phoenix_kit, secret_key_base: secret_key_base

       This is what every install used before the dedicated key existed, and
       it stays supported for backwards compatibility — but it means anyone
       who can read `secret_key_base` (env, config file, git history) can
       decrypt every stored integration credential, since that secret is
       shared with session signing, CSRF tokens, and everything else Phoenix
       derives from it. `status/0` reports this tier as
       `:legacy_secret_key_base`. `mix phoenix_kit.doctor`
       and the admin-only system page always surface it; a boot-time log line
       is also available (see `warn_if_insecure/0`) but OFF by default — set
       `config :phoenix_kit, integration_encryption_warn_on_boot: true` to
       have `PhoenixKit.boot/1` log it on every restart. That flag governs
       the boot report for every install where encryption works (the legacy
       key above, and key-store problems under a dedicated key). When
       credentials are stored as plaintext (`:disabled_no_key`,
       `:disabled_explicit`) the report is logged unless the flag is set to
       an explicit `false` and the state is `:disabled_explicit`, the one an
       operator chose; that also silences the one-time warning on the first
       plaintext write. `:disabled_no_key` means the key material went
       missing, and is reported whatever the flag says. `boot/1` resolves
       the key to learn which state the install is in, so the one-time error
       "a key store IS configured but its secret could not be read" may
       appear at boot even when the report itself is off. Only the boolean
       `false` silences `:disabled_explicit`: the string `"false"` (for
       example from `System.get_env/1`) is truthy and turns the full report
       on.

  Set `config :phoenix_kit, integration_encryption_enabled: false` to turn
  encryption off entirely (new and existing writes store plaintext). This is
  reported as `:disabled_explicit` by `status/0` and is warned about at boot
  unless `integration_encryption_warn_on_boot: false` is set as well.
  That flag does not silence `:disabled_no_key`: encryption is on there, but
  no key resolves, which is a fault rather than a choice.

  > #### Key rotation {: .warning}
  > Changing which secret produces the key — setting a dedicated key for the
  > first time, or rotating an existing one — makes every existing `enc:v1:`
  > value undecryptable under the new key. There is no dual-key fallback at
  > read time (that would silently mask a misconfigured key with plaintext
  > read failures, the opposite of the point). Use
  > `PhoenixKit.Integrations.KeyRotation.rotate/2` (or
  > `mix phoenix_kit.integrations.rotate_key`) to re-encrypt every stored
  > connection under the new secret BEFORE switching the app's config over
  > to it.
  >
  > A field that's temporarily undecryptable (mismatched key, mid-rotation)
  > is never permanently lost by an unrelated write in the meantime — see
  > `decrypt_fields_with_failures/1` and
  > `PhoenixKit.Integrations.save_setup/4`'s write path. The stored
  > ciphertext survives untouched until the correct key is active again.
  """

  require Logger

  alias PhoenixKit.Integrations.KeyStore

  # A dedicated key this short provides essentially no assurance over the
  # legacy fallback it's meant to replace — without a floor, a 1-character
  # `:integrations_encryption_key` reports as the healthy `:dedicated` tier
  # (banner hidden, no boot warning) just as confidently as a real random
  # secret would. Not an attempt at full entropy validation, just a floor
  # against the comically weak end.
  @min_dedicated_key_length 20

  # Fixed, ecosystem-wide: a per-install salt would give two installs holding the
  # same key different fingerprints, which is the one thing this must never do.
  @fingerprint_domain "phoenix_kit_integrations_fingerprint:v2"

  # Only raises the price of each guess; it cannot make a weak secret strong.
  # Costs roughly a tenth of a second, paid on an admin page mount and in a mix
  # task, neither of which is a hot path.
  @fingerprint_iterations 100_000

  @sensitive_fields ~w(
    access_token refresh_token client_secret
    api_key bot_token secret_key password
  )

  # Prefix to identify encrypted values
  @encrypted_prefix "enc:v1:"

  @typedoc """
  Which secret currently backs the encryption key, from most to least secure:

    * `:dedicated` — a dedicated `:integrations_encryption_key` is set.
    * `:legacy_secret_key_base` — no dedicated key; falling back to a key
      derived from `secret_key_base`. Functional, but shares its secret
      with the rest of the app.
    * `:disabled_no_key` — encryption is enabled but no key material at all
      resolves (neither a dedicated key nor a usable `secret_key_base`).
      New writes store plaintext.
    * `:disabled_explicit` — `integration_encryption_enabled: false`. New
      writes store plaintext.
  """
  @type key_status :: :dedicated | :legacy_secret_key_base | :disabled_no_key | :disabled_explicit

  @doc """
  Returns the list of field keys that are encrypted.
  """
  @spec sensitive_fields() :: [String.t()]
  def sensitive_fields, do: @sensitive_fields

  @doc """
  Encrypt sensitive fields in an integration data map before saving.

  Non-sensitive fields and nil/empty values are left unchanged.
  Already-encrypted values (with `enc:v1:` prefix) are not re-encrypted.

  When no key resolves (encryption switched off, or no key material at all)
  the data is returned as is and will be stored as plaintext; the first such
  write on a VM logs one warning, so the state is visible in the log of the
  node that is actually writing, not only at boot. An explicit
  `config :phoenix_kit, integration_encryption_warn_on_boot: false` skips
  that warning when encryption is switched off (`:disabled_explicit`), not
  when it is on and no key resolves (`:disabled_no_key`).
  """
  @spec encrypt_fields(map()) :: map()
  def encrypt_fields(data) when is_map(data) do
    case encryption_key() do
      nil ->
        warn_plaintext_write_once(data)
        data

      key ->
        do_encrypt_fields(data, key)
    end
  end

  @doc """
  Decrypt sensitive fields in an integration data map after reading.

  Only values with the `enc:v1:` prefix are decrypted.
  Non-encrypted values are returned as-is for backwards compatibility.
  """
  @spec decrypt_fields(map()) :: map()
  def decrypt_fields(data) when is_map(data) do
    {result, _failed} = decrypt_fields_with_failures(data)
    result
  end

  def decrypt_fields(other), do: other

  @doc """
  Same as `decrypt_fields/1`, but also returns the names of any fields that
  looked encrypted (carried the `enc:v1:` prefix) yet failed to decrypt
  under the currently active key.

  `decrypt_fields/1` drops an undecryptable field entirely — correct for
  every caller that treats the result as a live credential to use or
  display, since a caller must never mistake stale ciphertext for a real
  value. But `PhoenixKit.Integrations.resolve_uuid/2` also hands this same
  map to write paths that merge new attributes onto it and save the result
  wholesale: for THOSE callers, "absent because it failed to decrypt" and
  "absent because nothing was ever there" are not the same thing — the
  first must not be permanently erased by an unrelated write. The returned
  field-name list lets a write path restore an untouched field's original
  ciphertext from storage (see `PhoenixKit.Integrations.save_setup/4`,
  `refresh_access_token/1`, `exchange_code/4`, `record_validation/3`)
  without ever exposing that ciphertext as if it were usable.
  """
  @spec decrypt_fields_with_failures(map()) :: {map(), [String.t()]}
  def decrypt_fields_with_failures(data) when is_map(data) do
    case encryption_key() do
      nil -> strip_undecryptable_without_key(data)
      key -> do_decrypt_fields_tracking(data, key)
    end
  end

  # No key resolves (encryption disabled, or key store + secret_key_base
  # unavailable) but the row carries `enc:v1:` values: the map path used to
  # hand the ciphertext back as the live credential — the same silent
  # failure the wrong-key path already refuses. Treat those fields as absent
  # and say so, mirroring `maybe_decrypt_field/4`.
  defp strip_undecryptable_without_key(data) do
    Enum.reduce(@sensitive_fields, {data, []}, fn field, {acc, failed} ->
      case Map.get(acc, field) do
        @encrypted_prefix <> _ ->
          Logger.error(
            "[Integrations.Encryption] Field #{inspect(field)} is encrypted but no " <>
              "encryption key is available. Treating the credential as missing rather " <>
              "than returning ciphertext. " <> no_key_remedy()
          )

          {Map.delete(acc, field), [field | failed]}

        _ ->
          {acc, failed}
      end
    end)
  end

  @doc """
  Check if encryption is available and enabled.

  True for both the `:dedicated` and `:legacy_secret_key_base` tiers — this
  answers "will values be encrypted at all", not "how well". Use `status/0`
  to distinguish the two.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    encryption_key() != nil
  end

  @doc """
  Encrypt a single value, for callers with a bare field to protect rather
  than a full `encrypt_fields/1`-shaped map (e.g. an Ecto schema field like
  `PhoenixKit.Modules.Storage.Bucket.secret_access_key`).

  Same cipher, key derivation and `enc:v1:` prefix as `encrypt_fields/1`.
  Nil/empty and already-encrypted values (see `encrypted?/1`) pass through
  unchanged. When no key is in use (encryption switched off, or no key
  material at all), the value is stored as plaintext — same
  as `encrypt_fields/1` — and the first such call on a VM logs a warning,
  since a caller that reaches for single-value encryption is usually
  protecting something as sensitive as the fields `encrypt_fields/1`
  already covers, and a schema field silently staying plaintext is exactly
  the gap this API exists to close. Once per VM, like `encrypt_fields/1`:
  a bucket or setting save runs this per request. The same
  `integration_encryption_warn_on_boot: false` rule applies: it skips the
  warning for `:disabled_explicit`, never for `:disabled_no_key`.
  """
  @spec encrypt_value(String.t() | nil) :: String.t() | nil
  def encrypt_value(nil), do: nil
  def encrypt_value(""), do: ""

  def encrypt_value(value) when is_binary(value) do
    if encrypted?(value) do
      value
    else
      case encryption_key() do
        nil ->
          log_plaintext_once(
            :plaintext_value_logged,
            "PhoenixKit.Integrations.Encryption.encrypt_value/1: storing value as PLAINTEXT, " <>
              "no encryption key is in use: "
          )

          value

        key ->
          encrypt_value(value, key)
      end
    end
  end

  @doc """
  Decrypt a value produced by `encrypt_value/1`.

  Returns `{:ok, plaintext}`. A value without the `enc:v1:` prefix is
  returned as `{:ok, value}` unchanged — backwards compatibility with
  data written before encryption was applied. `{:error, :encryption_unavailable}`
  when the value IS prefixed but no encryption key is available (no
  `secret_key_base`) — unlike the nil-key path in `encrypt_value/1`, there
  is no plaintext to fall back to here, only ciphertext nobody can read
  right now. That case also logs one error per VM naming the setting to
  fix; a key is never derived from a missing secret. `{:error, reason}`
  for any other decrypt failure (wrong/rotated key, corrupted ciphertext).
  """
  @spec decrypt_value(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def decrypt_value(nil), do: {:ok, nil}
  def decrypt_value(""), do: {:ok, ""}

  def decrypt_value(value) when is_binary(value) do
    if encrypted?(value) do
      case encryption_key() do
        nil ->
          log_no_key_decrypt_once()
          {:error, :encryption_unavailable}

        key ->
          decrypt_value(value, key)
      end
    else
      {:ok, value}
    end
  end

  @doc """
  Reports which secret currently backs the encryption key. See `t:key_status/0`.

  Never touches the database, and safe to call from a boot hook or a LiveView
  `mount/3`. It is no longer pure config introspection: when a key store is
  configured it may read from it (memoised after the first success). A
  host-supplied store cannot crash this call — `PhoenixKit.Integrations.KeyStore`
  turns a raising store into an error tuple.
  """
  @spec status() :: key_status()
  def status do
    if encryption_enabled_flag?() do
      case resolve_tier() do
        {:dedicated, _secret} -> :dedicated
        {:legacy, _secret} -> :legacy_secret_key_base
        :none -> :disabled_no_key
      end
    else
      :disabled_explicit
    end
  end

  @typedoc """
  The active tier plus **why** it is that tier.

  Exists because two places give advice about the same situation —
  `warn_if_insecure/0` and `mix phoenix_kit.doctor` — and advice that is correct
  for one reason is actively harmful for another. Telling an operator whose key
  store is unreadable to run `mix phoenix_kit.integrations.rotate_key` would
  rotate away from a key their data may still be encrypted under. Telling
  someone who *did* configure a key that none is configured is simply false.

  Both callers branch on this one value, so they cannot drift apart.
  """
  @type key_diagnosis ::
          {:dedicated, :ok | :store_unreadable | :store_shadowed}
          | {:legacy_secret_key_base,
             :store_unreadable | :store_shadowed | :key_too_short | :no_dedicated_key}
          | {:disabled_no_key,
             :store_unreadable | :store_shadowed | :key_too_short | :no_key_material}
          | {:disabled_explicit, :turned_off}

  @doc """
  The active tier and the reason for it. See `t:key_diagnosis/0`.

  The reasons are ordered by what must be acted on first: an unreadable key
  store outranks "no dedicated key", because repairing the store may restore the
  very key the data is encrypted under, while rotating would abandon it.
  """
  @spec key_diagnosis() :: key_diagnosis()
  def key_diagnosis, do: key_report().diagnosis

  @typedoc """
  The raw signals the key state is made of, gathered in one pass.

  Deliberately separate from the verdict below. Everything that decides what an
  operator should be told is read here, once, and then the verdict is a function
  of this map alone — it consults nothing further. Three rounds of fixes each
  produced a message contradicting itself because a later step went back to the
  environment for one more fact and got a different answer than the step before.
  """
  @type key_signals :: %{
          enabled?: boolean(),
          tier: :dedicated | :legacy | :none,
          rejected_key: false | :config | :store,
          store:
            :absent
            | {:no_secret_yet, String.t()}
            | {:unreadable, String.t()}
            | {:shadowed, String.t()}
            | {:holding, String.t()},
          fingerprint: :none | {:ok, String.t()}
        }

  @typedoc """
  Everything a surface needs to say about the key state, decided together.

  One clause of `key_report/1` produces a whole one of these. There is no path
  by which its parts can disagree: the fingerprint and the tier that produced it
  are a single term, and `:key_store` is `nil` unless a store is actually
  configured.
  """
  @type key_report :: %{
          diagnosis: key_diagnosis(),
          severity: :ok | :warn | :fail,
          summary: String.t(),
          consequence: String.t(),
          action: String.t(),
          rotation_safe?: boolean(),
          rejected_key: false | :config | :store,
          fingerprint: :none | {:ok, String.t(), String.t()},
          key_store: nil | {:no_secret_yet | :unreadable | :shadowed | :holding, String.t()}
        }

  # ONE read of each input, and every signal derived from those three values.
  # This used to be four independent resolutions — the tier, the too-short
  # check, the store state and the fingerprint each went back to the
  # environment — and `KeyStore.cached_read/0` deliberately does not memoise
  # FAILURES, so a store that failed one read and answered the next produced a
  # map that contradicted itself. Reproduced before this changed, with a store
  # that fails only its first read:
  #
  #     tier: :legacy, store: {:holding, _}, fingerprint: {:ok, "2395aad025c3"}
  #     rendered as: "DERIVED from secret_key_base", "derived from secret_key_base"
  #     fp(secret_key_base) = 826f21f672e5   <- what the label claimed
  #     fp(stored secret)   = 2395aad025c3   <- what was printed
  #
  # The verdict being a pure function of this map buys nothing while the map is
  # itself stitched together from four different answers to the same question.
  @doc """
  Reads every signal the key verdict depends on, in one pass.
  """
  @spec key_signals() :: key_signals()
  def key_signals do
    enabled? = encryption_enabled_flag?()
    {{tier, secret, rejected_key}, _cached_read} = resolve_once()

    %{
      enabled?: enabled?,
      tier: tier,
      rejected_key: rejected_key,
      store: store_state(KeyStore.read(), secret),
      fingerprint: fingerprint_for(enabled?, secret)
    }
  end

  # Three absences the advice must keep apart, not two: no store at all, a store
  # that is configured and does not hold a secret yet, and a store that holds
  # one nobody can read. `KeyStore.read/0`'s own doc forbids collapsing the last
  # two — "no key yet" invites writing one, "could not read" must never lead to
  # overwriting one — and this function was collapsing the FIRST two instead: a
  # configured store whose file does not exist yet reads `:not_configured`, and
  # that was reported as `{:holding, _}`. Verified by running: a store pointed at
  # a path that does not exist produced `{:holding, "…/not-created-yet.key"}`,
  # so `{:no_secret_yet, _}` was a signal value production could never emit
  # while the tests enumerated it as one of four.
  # The KEY comes from the memoised read, because that is the key the running
  # app is actually encrypting with. The store's CONTENTS are read fresh, every
  # time, because a report about what a file holds must not be served from a
  # value cached at boot.
  #
  # The two are different questions and were being answered from one read. That
  # made the diagnosis unable to go out: an operator told "make the store hold
  # the key in use" could do exactly that and watch the warning persist until a
  # restart — visible in `mix phoenix_kit.doctor`, whose VM is new, and not on
  # the admin page, which is where they were told. A diagnosis that survives its
  # own remedy teaches people to ignore diagnoses, which is the opposite of what
  # this whole feature is for.
  #
  # This does not undo the one-pass property. The property is that everything
  # deciding WHICH KEY IS IN USE comes from a single resolution — it still does.
  # The fresh read decides nothing about the key; it only describes the file.
  defp store_state(store_read, key_in_use) do
    if KeyStore.configured?() do
      location = KeyStore.describe() || "the configured key store"

      case store_read do
        {:error, _reason} -> {:unreadable, location}
        :not_configured -> {:no_secret_yet, location}
        {:ok, ^key_in_use} -> {:holding, location}
        _other -> {:shadowed, location}
      end
    else
      :absent
    end
  end

  defp fingerprint_for(false, _secret), do: :none
  defp fingerprint_for(true, nil), do: :none
  defp fingerprint_for(true, secret), do: {:ok, fingerprint(derive_key(secret))}

  @doc """
  The complete report for the current state.
  """
  @spec key_report() :: key_report()
  def key_report, do: key_report(key_signals())

  @doc """
  The verdict for a set of signals — total over the signal space.

  Public because the acceptance criterion here is an enumeration: every
  combination rendered whole and read for self-contradiction. That needs a seam
  that takes the state rather than discovering it.

  ## Ordered by the tier first, and deliberately

  Three rounds ordered the clauses by fault — unreadable store, then short key,
  then tier — and each round found a state where the fault clause fired over a
  tier that was working, and announced a fallback that was not happening. The
  fix each time was to move one clause; the next round found the next one.

  The tier is the ground truth: it is *which key is protecting the data right
  now*. A fault is a modifier on that, never a replacement for it. So the tier
  is matched first and the fault second, which has two consequences worth
  stating:

    * no combination of signals can produce a report claiming a fallback while
      the signals say a dedicated key is in use — not because that combination
      is argued to be unreachable, but because no clause can say it;
    * the verdict is **total**. Every point in the signal space renders, and the
      test walks all of them rather than filtering by a reachability rule.
      Reachability rules were themselves the defect twice: they were reasoned
      out by whoever reasoned out the code, and they excluded states the code
      could actually reach.

  Within a tier, the faults are ordered by which one an operator must clear
  first. For the weaker tiers a rejected key outranks an unreadable store,
  because `dedicated_candidate/2` never consults the store while config answers
  — so repairing the store cannot change anything until the short key is gone.
  """
  @spec key_report(key_signals()) :: key_report()

  # Turned off deliberately. Nothing below matters — a short key or an unread
  # store is irrelevant when no encryption is being attempted.
  def key_report(%{enabled?: false} = signals) do
    report(signals, {:disabled_explicit, :turned_off}, :warn,
      summary: "encryption is switched off (integration_encryption_enabled: false)",
      consequence:
        "integration credentials are being written in PLAINTEXT, readable by anyone with " <>
          "read access to the database",
      action: "If that is unintentional, set integration_encryption_enabled: true",
      rotation_safe?: false,
      tier_label: nil
    )
  end

  # --- the dedicated tier: a key of this site's own is doing the work --------

  # Encryption is working; what is broken is the spare copy. The consequence
  # used to promise that "the next rotation will refuse at its pre-flight",
  # which was false twice over, and both halves were checked by running:
  #
  #   * `KeyStore.preflight/0` writes a probe file NEXT TO the secret and
  #     removes it. An unreadable secret in a writable directory answers `:ok`;
  #   * `KeyRotation.rotate/2` does not run a pre-flight at all. With
  #     `preflight/0` returning `{:error, {:inside_repository, _}}`, `rotate/2`
  #     walked straight past it into the row scan. Only the mix task checks.
  def key_report(%{tier: :dedicated, store: {:unreadable, location}} = signals) do
    report(signals, {:dedicated, :store_unreadable}, :warn,
      summary:
        "a dedicated encryption key is in use, but the configured key store could not be read",
      consequence:
        "encryption itself is fine — the key in use comes from configuration. What is broken " <>
          "is the spare copy: nothing confirms this key is saved anywhere, and a rotation " <>
          "will not be stopped by it, because the pre-flight checks that the store can be " <>
          "WRITTEN, not that it can be read",
      action:
        "Do NOT run `mix phoenix_kit.integrations.rotate_key` until the store reads back — " <>
          "repair it at #{location} first, and until it does, assume the key is saved nowhere",
      rotation_safe?: false,
      tier_label: "dedicated key"
    )
  end

  # The store holds a secret, and it is NOT the one doing the work. Both values
  # were already in hand — `key_signals/0` reads the stored secret and resolves
  # the key in use in the same pass — and the verdict used to print the store's
  # location under a healthy `{:dedicated, :ok}` without ever comparing them.
  # The line says "a store is configured at /path"; underneath "a dedicated
  # encryption key is in use" it reads as "your key is saved there", and that
  # reading was never checked.
  #
  # Two ways it costs, both verified by running:
  #
  #   * restoring the key from the store yields a secret that decrypts nothing
  #     written under the current one;
  #   * `mix phoenix_kit.integrations.rotate_key` replaces what the store holds
  #     and keeps no copy — `KeyStore.Chain` writes every member, so the local
  #     file and any off-host copy go together. Rotation refuses only while THIS
  #     database still has rows under the stored secret; where it has none it
  #     proceeds, and it stores the new secret even after rotating zero rows.
  #     The destructive path is the quiet one.
  def key_report(%{tier: :dedicated, store: {:shadowed, location}} = signals) do
    report(signals, {:dedicated, :store_shadowed}, :warn,
      summary:
        "a dedicated encryption key is in use, but the configured key store holds a " <>
          "different secret",
      consequence:
        "#{location} holds something other than the key in use, so it is NOT a copy of that " <>
          "key: restoring from it would produce a key that decrypts nothing written under " <>
          "the current one. If you have just changed what the store holds, this app is still " <>
          "on the key it resolved at boot — restart to pick the new one up",
      action:
        "Do NOT run `mix phoenix_kit.integrations.rotate_key` before you know what the " <>
          "stored secret is for. It stops for two things — a key store it cannot WRITE to, " <>
          "and any row it cannot decrypt under the active key, whatever the cause — and " <>
          "neither is a check on the stored secret. Where neither happens the rotation " <>
          "replaces it in every configured store with no copy kept. Save it elsewhere " <>
          "first, or make the store hold the key in use",
      rotation_safe?: false,
      tier_label: "dedicated key"
    )
  end

  def key_report(%{tier: :dedicated} = signals) do
    report(signals, {:dedicated, :ok}, :ok,
      summary: "a dedicated encryption key is in use",
      consequence: "",
      action: "",
      rotation_safe?: true,
      tier_label: "dedicated key"
    )
  end

  # --- the legacy tier: secret_key_base is doing the work --------------------

  # Ordered above the unreadable store, unlike every earlier round. While a
  # rejected key is set in config the store is never consulted (verified by
  # running), so "repair the store" is advice that cannot help until this is
  # cleared — and it is the only clause that says so.
  def key_report(%{tier: :legacy, rejected_key: source} = signals) when source != false do
    report(signals, {:legacy_secret_key_base, :key_too_short}, :warn,
      summary: too_short_summary(signals.rejected_key),
      consequence: fallback_consequence(),
      action: replace_key_action(signals),
      rotation_safe?: true,
      tier_label: too_short_label(signals.rejected_key)
    )
  end

  def key_report(%{tier: :legacy, store: {:unreadable, location}} = signals) do
    report(signals, {:legacy_secret_key_base, :store_unreadable}, :warn,
      summary: "a key store is configured (#{location}) but its secret could not be read",
      consequence: fallback_consequence(),
      action: repair_store_action(:fallback),
      rotation_safe?: false,
      tier_label: "FALLBACK key — the configured key store could not be read"
    )
  end

  # The window between a rotation and the restart it requires: the store
  # already holds a secret that is NOT the one this process is using (still
  # the secret_key_base-derived fallback), most plausibly because
  # `mix phoenix_kit.integrations.rotate_key` already wrote a dedicated
  # secret there and this process has not restarted onto it yet. Mirrors
  # `{:dedicated, :store_shadowed}` above: `rotation_safe?: false` for the
  # same reason — rotating again before checking what is already saved would
  # replace it in every configured store with no copy kept, possibly
  # discarding the very secret that just needs a restart to take effect.
  def key_report(%{tier: :legacy, store: {:shadowed, location}} = signals) do
    report(signals, {:legacy_secret_key_base, :store_shadowed}, :warn,
      summary:
        "credentials are encrypted with a key DERIVED from secret_key_base, and the " <>
          "configured key store holds a secret that is NOT that key",
      consequence:
        fallback_consequence() <>
          ". #{location} is not a copy of the fallback key in use, so it is not a backup " <>
          "of it either — it most plausibly already holds a dedicated secret from a " <>
          "rotation this app has not restarted to pick up yet",
      action:
        "Do NOT run `mix phoenix_kit.integrations.rotate_key` before you know what " <>
          "#{location} holds — it replaces that secret in every configured store with no " <>
          "copy kept. If a rotation already wrote it, restart the app to start using it " <>
          "instead of rotating again",
      rotation_safe?: false,
      tier_label: "FALLBACK key — the configured key store holds a different secret"
    )
  end

  def key_report(%{tier: :legacy} = signals) do
    report(signals, {:legacy_secret_key_base, :no_dedicated_key}, :warn,
      summary: "integration credentials are encrypted with a key DERIVED from secret_key_base",
      consequence:
        "secret_key_base is shared with session signing and CSRF tokens, so anyone who can " <>
          "read it (environment, a config file, git history) can decrypt every stored " <>
          "credential — and any other site sharing that secret_key_base holds the same key",
      action:
        "Run `mix phoenix_kit.integrations.rotate_key` for a key of this site's own, then " <>
          "restart",
      rotation_safe?: true,
      tier_label: "derived from secret_key_base"
    )
  end

  # --- no tier at all: everything is going to the database in the clear ------

  # `rotation_safe?` is false for every clause here and the advice says why:
  # `KeyRotation.rotate/2` refuses outright while no key is active, verified by
  # running — `{:error, {:encryption_disabled, :disabled_no_key}}`. This clause
  # used to advise the rotation anyway and mark it safe, which is the same
  # wrong recommendation an earlier round removed from the clause next to it.
  def key_report(%{tier: :none, rejected_key: source} = signals) when source != false do
    report(signals, {:disabled_no_key, :key_too_short}, :fail,
      summary: too_short_summary(signals.rejected_key),
      consequence:
        "NO key resolved at all — integration credentials are being written in PLAINTEXT",
      action:
        "Do NOT run `mix phoenix_kit.integrations.rotate_key` — it refuses while no key is " <>
          "active. Replace the rejected secret — #{rejected_secret_location(signals)} — with " <>
          "one of at least #{@min_dedicated_key_length} characters and restart",
      rotation_safe?: false,
      tier_label: nil
    )
  end

  def key_report(%{tier: :none, store: {:unreadable, location}} = signals) do
    report(signals, {:disabled_no_key, :store_unreadable}, :fail,
      summary: "a key store is configured (#{location}) but its secret could not be read",
      consequence:
        "NO key resolved at all — integration credentials are being written in PLAINTEXT",
      action: repair_store_action(:no_key),
      rotation_safe?: false,
      tier_label: nil
    )
  end

  # Same window as the :legacy clause above, one step weaker: no key resolves
  # AT ALL (not even the secret_key_base fallback), yet the store already
  # holds something — most plausibly a dedicated secret from a rotation this
  # app has not been configured or restarted to use yet.
  def key_report(%{tier: :none, store: {:shadowed, location}} = signals) do
    report(signals, {:disabled_no_key, :store_shadowed}, :fail,
      summary: "no encryption key resolves at all, and the configured key store holds a secret",
      consequence:
        "NO key resolved at all — integration credentials are being written in PLAINTEXT. " <>
          "#{location} holds a secret, but nothing here is using it: if it is a dedicated " <>
          "key from an earlier rotation, this app has not yet been configured or restarted " <>
          "to use it",
      action:
        "Do NOT run `mix phoenix_kit.integrations.rotate_key` — it refuses while no key is " <>
          "active. Check what #{location} holds first; if it is a real key, wire it in as " <>
          "integrations_encryption_key (or fix why it is not being read from the store) and " <>
          "restart",
      rotation_safe?: false,
      tier_label: nil
    )
  end

  def key_report(%{tier: :none} = signals) do
    report(signals, {:disabled_no_key, :no_key_material}, :fail,
      summary: "no encryption key resolves at all",
      consequence:
        "integration credentials (API keys, OAuth tokens, bot tokens) are being written in " <>
          "PLAINTEXT, readable by anyone with read access to the database",
      action: no_key_action(signals.store),
      rotation_safe?: false,
      tier_label: nil
    )
  end

  # Assembles the report so that no clause can forget a field or pair a
  # fingerprint with a label from a different state: the label arrives with the
  # verdict, and the value with the signals, and they are joined here once.
  defp report(signals, diagnosis, severity, fields) do
    %{
      diagnosis: diagnosis,
      severity: severity,
      summary: Keyword.fetch!(fields, :summary),
      consequence: Keyword.fetch!(fields, :consequence),
      action: Keyword.fetch!(fields, :action),
      rotation_safe?: Keyword.fetch!(fields, :rotation_safe?),
      # Carried for the same reason `:key_store` is: a surface that renders the
      # facts in its own words must be GIVEN the facts it puts in them. The
      # admin page was handed only the diagnosis and still described where the
      # rejected key lives — a claim about `dedicated_candidate/2`'s behaviour
      # that nothing had told it. That held while a rejected key could only come
      # from config; the moment the store could supply one, the page went on
      # saying "the key store is not consulted at all" about the very file the
      # secret was read from.
      rejected_key: signals.rejected_key,
      fingerprint: label_fingerprint(signals.fingerprint, Keyword.fetch!(fields, :tier_label)),
      key_store: store_location(signals.store)
    }
  end

  defp label_fingerprint(:none, _label), do: :none
  defp label_fingerprint({:ok, _value}, nil), do: :none
  defp label_fingerprint({:ok, value}, label), do: {:ok, value, label}

  # The location alone reads as "your key is saved here", which is exactly what
  # it does NOT mean for two of the three states — and one of those states could
  # not even be produced until `store_state/1` stopped collapsing it.
  defp store_location(:absent), do: nil
  defp store_location({state, location}), do: {state, location}

  defp fallback_consequence,
    do:
      "encryption fell back to the secret_key_base-derived key, so values written under " <>
        "the stored key will not decrypt, and anything written now is encrypted under the " <>
        "fallback instead"

  defp repair_store_action(:fallback),
    do:
      "Do NOT run `mix phoenix_kit.integrations.rotate_key` to fix this — the stored key " <>
        "may still be the one your data is encrypted under. Repair the store first; " <>
        "repairing it later will NOT make anything written in the meantime readable"

  # The sentence above is false here, and false in the direction that matters.
  # With no key resolving, what is being written is not ciphertext under a
  # weaker key — it is PLAINTEXT (verified by running `encrypt_fields/1` in this
  # state: the value is stored verbatim). Repairing the store later leaves those
  # rows exactly as readable as they are now, to anyone with database access.
  # They do not need decrypting; they need rewriting.
  defp repair_store_action(:no_key),
    do:
      "Do NOT run `mix phoenix_kit.integrations.rotate_key` — it refuses while no key is " <>
        "active, and the stored key may be the one existing credentials are encrypted under. " <>
        "Repair the store first: every credential written meanwhile goes to the database in " <>
        "the clear and STAYS readable after the repair, so re-save those connections once a " <>
        "key is active"

  # The eighth instance of the same premise, in the last two places that still
  # carried it: both said "a dedicated key IS configured" whatever the source, so
  # an operator whose short secret is in the key store read that sentence in the
  # same paragraph as "no integrations_encryption_key is set". The advice was
  # already right by then; what was left was a description contradicting it.
  #
  # The config wording is unchanged, byte for byte — it is correct where it now
  # applies, and rewording it would churn a translated string for nothing.
  defp too_short_summary(:store),
    do:
      "the secret in the key store was rejected as shorter than " <>
        "#{@min_dedicated_key_length} characters, which is not the same as having no key " <>
        "at all"

  defp too_short_summary(_source),
    do:
      "a dedicated key IS configured but was rejected as shorter than " <>
        "#{@min_dedicated_key_length} characters, which is not the same as none being " <>
        "configured"

  defp too_short_label(:store),
    do: "FALLBACK key — the secret in the key store was rejected as too short"

  defp too_short_label(_source), do: "FALLBACK key — the configured key was rejected as too short"

  # WHERE the rejected secret lives decides the whole advice, and it is a
  # property of the RESOLUTION, not of the store's state — which is what the
  # previous attempt got wrong. That version derived the source from the store
  # signal, and the derivation held only while `{:holding, _}` meant "the store
  # has a secret". When P012 made `{:holding, _}` mean "the store has THE KEY IN
  # USE", the state this clause exists for — a short secret in the store and no
  # config key at all — silently became `{:shadowed, _}` and started rendering
  # "Replace integrations_encryption_key", a variable the operator does not
  # have. A claim resting on a neighbour's classification, and the neighbour
  # moved.
  #
  # `dedicated_candidate/2` already knows: config answers first, and only when
  # it does not does the store's secret get length-checked. So the source is
  # carried out of the resolution rather than guessed back from a signal that
  # answers a different question.
  defp replace_key_action(signals),
    do:
      "Replace the rejected secret — #{rejected_secret_location(signals)}. " <>
        "`mix phoenix_kit.integrations.rotate_key` generates a replacement, and stores it " <>
        "for you if a key store is configured"

  defp rejected_secret_location(%{rejected_key: :store, store: {_state, location}}),
    do:
      "it is the secret in #{location}; no integrations_encryption_key is set, so the store " <>
        "is what the key is read from"

  defp rejected_secret_location(%{rejected_key: :config}),
    do:
      "it is integrations_encryption_key. Config wins while it is set, so the key store is " <>
        "not consulted at all and repairing or filling it changes nothing"

  # A rejected key with no home the signals can name is not a state the
  # resolution produces — `:store` always comes with a store, `:config` always
  # with the config key. Rendered anyway, because the verdict is total, and
  # deliberately without naming a location it cannot justify.
  defp rejected_secret_location(_signals), do: "it is the configured encryption key"

  # The two absences the reviewer asked to keep apart: nothing configured at all
  # versus a store that is configured and empty. Set one up, versus put a secret
  # into the one you have.
  defp no_key_action(:absent),
    do: "Configure integrations_encryption_key, or a key store, and restart"

  # NOT "run rotate_key": rotation refuses outright while no key is active
  # (`KeyRotation.rotate/2` returns `{:error, {:encryption_disabled, _}}`), so
  # that advice would send an operator to a command that cannot help them. The
  # store being configured and empty is still worth saying — it is the
  # difference between "set one up" and "you have one, it is just empty".
  defp no_key_action({:no_secret_yet, location}),
    do:
      "A key store is configured at #{location} but holds no secret yet. Set " <>
        "integrations_encryption_key and restart; rotation cannot help while no key is active"

  defp no_key_action({_state, location}),
    do: "Check the key store at #{location}, then restart"

  @doc """
  The report rendered as one sentence, for a log line.

  Never includes the fingerprint: a log's readership is wider than the admin
  page's, and the fingerprint is a verifier against candidate secrets.
  """
  @spec key_report_message(key_report()) :: String.t()
  def key_report_message(report) do
    [report.summary, report.consequence, report.action]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(". ")
  end

  @doc """
  A short, non-reversible fingerprint of the key currently in use, or `:none`.

  Exists so that **key reuse between sites is visible**. `derive_key/1` is a
  plain SHA-256 over the secret, so two installs that share a `secret_key_base`
  — copied from a template, cloned from a sibling environment, inherited with a
  `config/dev.exs` — derive a byte-identical integration key and neither has any
  way to notice. One compromise then exposes every site that shares it.

  Two installs showing the same fingerprint are using the same key.

  ## Comparing two numbers only means something like-for-like

  Three things make one site show a fingerprint that is not "its" key, and none
  of them are visible in the number itself, so **always read the tier printed
  next to it**:

    * an unreadable key store, so the fallback key is being fingerprinted;
    * a dedicated key rejected as too short, same effect;
    * encryption disabled, in which case there is no fingerprint at all.

  There is also an environment trap. `mix phoenix_kit.doctor` resolves the key
  in the **task's** environment; a key delivered by an env var read in
  `runtime.exs` may differ from what the running server holds. A task and an
  admin page on the same site can therefore disagree. Compare admin page with
  admin page, or task with task.

  ## What it gives away

  Domain-separated from `derive_key/1` and truncated, so it is not the key and
  cannot be turned back into one. It IS a verifier: anyone holding it can test
  candidate secrets offline.

  There is no salt, and there cannot be one — a per-install salt would make two
  installs with the same key show different numbers, destroying the only thing
  this is for. What can be raised is the cost per guess, so the digest is
  iterated (PBKDF2-HMAC-SHA256, #{@fingerprint_iterations} iterations) instead
  of the two plain hashes it used to be. The prefix is global to PhoenixKit, so
  a table over common `secret_key_base` values works against every install at
  once; iteration makes building that table that many times more expensive, and
  nothing more. **The fingerprint is no stronger than the secret behind it** —
  against a weak, guessable secret it is a verification oracle, which is exactly
  the situation this feature exists to surface.

  Accordingly it is shown on the admin-only system page, and by
  `mix phoenix_kit.doctor` only when explicitly asked for: a task's output ends
  up in CI logs, whose readership is wider than the page's.
  """
  @spec key_fingerprint() :: {:ok, String.t()} | :none
  def key_fingerprint do
    case encryption_key() do
      key when is_binary(key) -> {:ok, fingerprint(key)}
      _ -> :none
    end
  end

  defp fingerprint(key) do
    :sha256
    |> :crypto.pbkdf2_hmac(key, @fingerprint_domain, @fingerprint_iterations, 6)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Shortest secret accepted as a dedicated key.

  Public so `mix phoenix_kit.integrations.rotate_key` can refuse a `--new-key`
  this module would later reject: without the check the rotation "succeeds",
  the data is re-encrypted, and the app silently drops to a weaker tier on the
  next restart.
  """
  @spec min_dedicated_key_length() :: pos_integer()
  def min_dedicated_key_length, do: @min_dedicated_key_length

  @doc """
  Logs a warning when integration credentials are not protected by a
  dedicated key. Deliberately silent (no log line) for the healthy
  `:dedicated` case; the common, correctly-configured install must produce
  zero noise here.

  This function itself is unconditional — every call evaluates `key_report/0`
  and logs if it isn't `:ok`. What's opt-in is *who calls it at boot*:
  `PhoenixKit.boot/1` invokes it when
  `config :phoenix_kit, integration_encryption_warn_on_boot: true` is set
  (unset by default), since otherwise every install still on the legacy
  `secret_key_base` fallback would get this log line on every single restart
  with no way to quiet it. The exception is plaintext storage
  (`status/0` is `:disabled_no_key` or `:disabled_explicit`): `boot/1` calls
  this function in that case too. An explicit `false` skips the call for
  `:disabled_explicit` only; `:disabled_no_key` is reported regardless.
  `boot/1` resolves the key to learn
  the state, so the one-time error "a key store IS configured but its
  secret could not be read" may be logged at boot even when this report is
  not. `mix phoenix_kit.doctor`
  and the admin-only system page render `key_report/0` directly, independent
  of this flag, so the diagnosis is always available on demand even when the
  boot push is off.

  An `:integrations_encryption_key` shorter than the minimum length gets
  its OWN message rather than being folded into the "no dedicated key"
  wording below — an operator who set one, just too short, needs
  different advice than one who never set it, and telling them "no
  dedicated key is configured" when they configured one is simply false.

  Never raises — returns `:ok` unconditionally.
  """
  @spec warn_if_insecure() :: :ok
  def warn_if_insecure do
    report = key_report()

    case report.severity do
      :ok -> :ok
      :fail -> Logger.error("[PhoenixKit.Integrations] " <> key_report_message(report))
      :warn -> Logger.warning("[PhoenixKit.Integrations] " <> key_report_message(report))
    end

    :ok
  end

  @doc """
  Encrypts sensitive fields using an EXPLICIT secret, bypassing the
  configured-key resolution entirely — the rotation primitive.

  `secret` is derived the same way a configured key would be
  (`derive_key/1`); this does not read `:integrations_encryption_key` or
  `secret_key_base`. Used by `PhoenixKit.Integrations.KeyRotation` to write
  values under a NEW secret before that secret becomes the active
  configured key — which is the whole point of rotation: the new key must
  be usable to encrypt before it's the one `encryption_key/0` resolves to.
  """
  @spec encrypt_fields_with_secret(map(), String.t()) :: map()
  def encrypt_fields_with_secret(data, secret)
      when is_map(data) and is_binary(secret) and secret != "" do
    do_encrypt_fields(data, derive_key(secret))
  end

  @doc """
  Encrypts a single value using an EXPLICIT secret — the single-value
  counterpart to `encrypt_fields_with_secret/2`, for the same rotation
  use case (`PhoenixKit.Integrations.KeyRotation` re-encrypting
  `PhoenixKit.Settings`' restricted setting values, which are stored as a
  bare `value` string rather than a `value_json` map of sensitive fields).

  Nil/empty pass through unchanged, same as `encrypt_value/1`. Unlike
  `encrypt_value/1`, does NOT skip already-encrypted input — rotation
  always calls this with a value it just decrypted under the OLD key, so
  by the time it reaches here it is plaintext, never still `enc:v1:`-prefixed.
  """
  @spec encrypt_value_with_secret(String.t() | nil, String.t()) :: String.t() | nil
  def encrypt_value_with_secret(nil, _secret), do: nil
  def encrypt_value_with_secret("", _secret), do: ""

  def encrypt_value_with_secret(value, secret)
      when is_binary(value) and is_binary(secret) and secret != "" do
    encrypt_value(value, derive_key(secret))
  end

  @doc """
  Whether `value` looks like an already-encrypted field value (carries the
  current `enc:v1:` prefix).

  Used to keep `encrypt_value/1` idempotent (never double-encrypt) and to
  let callers tell an already-migrated field apart from legacy plaintext.
  Also public so callers outside this module —
  `PhoenixKit.Integrations.KeyRotation` detecting which fields were
  encrypted before a rotation — don't hardcode the prefix literal
  themselves. A future `enc:v2:` format only needs to update this one
  place.
  """
  @spec encrypted?(term()) :: boolean()
  def encrypted?(value) when is_binary(value), do: String.starts_with?(value, @encrypted_prefix)
  def encrypted?(_value), do: false

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Logged only when a plaintext credential is actually about to be stored, and
  # once per VM: this runs per save, so it would otherwise repeat per request.
  # The message is the same rendered report the boot check uses — it names the
  # state and the location of a key store, never a field value.
  # An explicit `integration_encryption_warn_on_boot: false` is the operator
  # saying "I turned encryption off and know credentials are plaintext". It
  # does not cover `:disabled_no_key`: there encryption is on and the key went
  # missing, which nobody chose. Checked last in the caller, so the key is
  # resolved only for a write that would otherwise warn.
  defp plaintext_warning_silenced? do
    Application.get_env(:phoenix_kit, :integration_encryption_warn_on_boot) == false and
      status() != :disabled_no_key
  end

  defp warn_plaintext_write_once(data) do
    if plaintext_sensitive_value?(data) do
      log_plaintext_once(
        :plaintext_write_logged,
        "[PhoenixKit.Integrations] Storing integration credentials as PLAINTEXT, " <>
          "no encryption key is in use: "
      )
    end

    :ok
  end

  # One latch per caller (`encrypt_fields/1`, `encrypt_value/1`), so a
  # plaintext bucket secret is still reported after an integration write
  # already was.
  defp log_plaintext_once(latch, prefix) do
    key = {__MODULE__, latch}

    if :persistent_term.get(key, false) == false and not plaintext_warning_silenced?() do
      report = key_report()

      # The key can appear between the caller's lookup and this report; then
      # the text would contradict itself ("no key is in use: a dedicated key
      # is in use"), and there is nothing to warn about anyway.
      if report.severity != :ok do
        :persistent_term.put(key, true)
        Logger.warning(prefix <> key_report_message(report))
      end
    end

    :ok
  end

  defp plaintext_sensitive_value?(data) do
    Enum.any?(@sensitive_fields, fn field ->
      case Map.get(data, field) do
        value when is_binary(value) and value != "" ->
          not String.starts_with?(value, @encrypted_prefix)

        _ ->
          false
      end
    end)
  end

  defp do_encrypt_fields(data, key) do
    Enum.reduce(@sensitive_fields, data, fn field, acc ->
      case Map.get(acc, field) do
        nil ->
          acc

        "" ->
          acc

        value when is_binary(value) ->
          if String.starts_with?(value, @encrypted_prefix) do
            # Already encrypted
            acc
          else
            Map.put(acc, field, encrypt_value(value, key))
          end

        _ ->
          acc
      end
    end)
  end

  defp do_decrypt_fields_tracking(data, key) do
    Enum.reduce(@sensitive_fields, {data, []}, fn field, {acc, failed_fields} ->
      case Map.get(acc, field) do
        value when is_binary(value) and value != "" ->
          case maybe_decrypt_field(acc, field, value, key) do
            {:ok, new_acc} -> {new_acc, failed_fields}
            {:failed, new_acc} -> {new_acc, [field | failed_fields]}
          end

        _ ->
          {acc, failed_fields}
      end
    end)
  end

  defp maybe_decrypt_field(acc, field, value, key) do
    if String.starts_with?(value, @encrypted_prefix) do
      case decrypt_value(value, key) do
        {:ok, plaintext} ->
          {:ok, Map.put(acc, field, plaintext)}

        {:error, reason} ->
          # Returning `acc` unchanged here used to hand back the raw
          # `enc:v1:...` ciphertext as if it were the live credential —
          # silently, with no log line. Downstream code (bearer-token
          # resolution, "has credentials?" checks) has no idea that string
          # isn't a real secret, so a key change without running
          # `PhoenixKit.Integrations.KeyRotation.rotate/2` first produced a
          # garbled Authorization header instead of a loud, diagnosable
          # failure. Treat an undecryptable field as absent instead — the
          # `:failed` tag lets `decrypt_fields_with_failures/1` tell a write
          # path this field is absent ONLY because it can't be read right
          # now, not because it was never there.
          Logger.error(
            "[Integrations.Encryption] Failed to decrypt field #{inspect(field)} " <>
              "(#{inspect(reason)}) — the active key does not match the one this value was " <>
              "encrypted under. Treating the credential as missing rather than returning " <>
              "ciphertext. If you just changed the encryption key/secret_key_base, run " <>
              "mix phoenix_kit.integrations.rotate_key first."
          )

          {:failed, Map.delete(acc, field)}
      end
    else
      {:ok, acc}
    end
  end

  defp encrypt_value(plaintext, key) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", true)
    encoded = Base.encode64(iv <> tag <> ciphertext)
    @encrypted_prefix <> encoded
  end

  defp decrypt_value(@encrypted_prefix <> encoded, key) do
    with {:ok, binary} <- Base.decode64(encoded),
         <<iv::binary-12, tag::binary-16, ciphertext::binary>> <- binary do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decryption_failed}
      end
    else
      _ -> {:error, :invalid_format}
    end
  end

  defp decrypt_value(_, _key), do: {:error, :not_encrypted}

  defp encryption_key do
    if encryption_enabled_flag?() do
      case resolve_tier() do
        {_tier, secret} -> derive_key(secret)
        :none -> nil
      end
    else
      nil
    end
  end

  defp encryption_enabled_flag? do
    Application.get_env(:phoenix_kit, :integration_encryption_enabled, true)
  end

  # `:dedicated` (an explicit `:integrations_encryption_key`) always wins over
  # `:legacy` (the secret_key_base-derived fallback) — a host that has set up
  # a dedicated key has already opted into the safer tier, and silently
  # preferring the legacy one for some values would leave part of the data
  # under the weaker key with no way to tell which.
  defp resolve_tier do
    case resolve_once() do
      {{:none, _secret, _short?}, _store_read} -> :none
      {{tier, secret, _short?}, _store_read} -> {tier, secret}
    end
  end

  # One store read, one resolution, and the store-failure log emitted from
  # inside it — so the log knows which tier actually resolved instead of
  # guessing from the environment.
  defp resolve_once do
    store_read = read_store()
    resolution = resolve(configured_key(), store_read, secret_key_base())
    maybe_log_store_failure(store_read, resolution)
    {resolution, store_read}
  end

  # The whole tier resolution as a pure function of the three raw reads, so the
  # hot path and the diagnostics cannot reach different conclusions about the
  # same inputs — they no longer read the inputs separately.
  @spec resolve(term(), term(), String.t() | nil) ::
          {:dedicated | :legacy | :none, String.t() | nil, boolean()}
  defp resolve(config_key, store_read, secret_key_base) do
    case dedicated_candidate(config_key, store_read) do
      {:ok, secret} ->
        {:dedicated, secret, false}

      candidate ->
        rejected_key =
          case candidate do
            {:too_short, source} -> source
            :unset -> false
          end

        case secret_key_base do
          secret when is_binary(secret) and secret != "" -> {:legacy, secret, rejected_key}
          _ -> {:none, nil, rejected_key}
        end
    end
  end

  # Explicit configuration wins, and the store is not consulted at all when
  # config answers — INCLUDING when what it answers with is rejected as too
  # short. That is not a detail of ordering: verified by running, a store
  # holding a perfectly good secret resolves to `:dedicated` on its own and
  # drops to `:legacy_secret_key_base` the moment a short
  # `:integrations_encryption_key` is added. So while a rejected key sits in
  # config, repairing or filling the key store changes nothing, and any advice
  # that says otherwise is sending an operator to the wrong file.
  #
  # A secret persisted by `PhoenixKit.Integrations.KeyStore` is the same
  # `:dedicated` tier — a dedicated key the operator did not have to paste into
  # config by hand after rotating.
  defp dedicated_candidate({:ok, secret}, _store_read) when is_binary(secret) and secret != "",
    do: check_dedicated_length(secret, :config)

  defp dedicated_candidate(_config, {:ok, secret}) when is_binary(secret) and secret != "",
    do: check_dedicated_length(secret, :store)

  defp dedicated_candidate(_config, _store_read), do: :unset

  defp configured_key, do: PhoenixKit.Config.get(:integrations_encryption_key)

  # Reads the store through the memoised path — encryption runs once per
  # encrypted field, and an unmemoised read would open a file every time.
  #
  # A configured store that cannot be READ is not the same as no store, and
  # collapsing the two is how a fleet quietly splits in half: the app falls
  # through to the weaker `:legacy` tier, old values stop decrypting, and NEW
  # values get written under the legacy key. Fixing the file later then leaves
  # those new rows unreadable forever. The fallback is kept — refusing outright
  # would resolve to no key at all, and a nil key makes writes store plaintext,
  # which is worse — but it is never silent.
  defp read_store, do: KeyStore.cached_read()

  defp maybe_log_store_failure({:error, reason}, {tier, _secret, _short?}),
    do: log_store_failure_once(reason, tier)

  defp maybe_log_store_failure(_store_read, _resolution), do: :ok

  # Encryption runs once per credential field and read failures are deliberately
  # not cached, so this would otherwise repeat per field, per request. One line
  # per VM is enough to be found.
  defp log_store_failure_once(reason, tier) do
    key = {__MODULE__, :store_failure_logged}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.error(
        "[PhoenixKit.Integrations] A key store IS configured but its secret could not be " <>
          "read (#{KeyStore.describe_error(reason)}): #{weaker_tier_consequence(tier)}. " <>
          "#{store_failure_urgency(tier)}"
      )
    end

    :ok
  end

  defp check_dedicated_length(secret, source) do
    if String.length(secret) >= @min_dedicated_key_length,
      do: {:ok, secret},
      else: {:too_short, source}
  end

  # Flat `config :phoenix_kit, secret_key_base: ...` keeps precedence — it's
  # what an operator who deliberately set it expects to keep working. The
  # installer never stamps that key, though, so most host apps never set
  # it and encryption silently stayed disabled (secrets stored in
  # plaintext). Fall back to the host app's own Endpoint secret_key_base,
  # which every Phoenix app has — same discovery `Config.get_parent_endpoint/0`
  # already uses elsewhere (derived from `:parent_module`, which the
  # installer does set).
  defp secret_key_base do
    case PhoenixKit.Config.get(:secret_key_base) do
      {:ok, secret} when is_binary(secret) and secret != "" -> secret
      _ -> endpoint_secret_key_base()
    end
  end

  # The running endpoint first, then the endpoint's own app env.
  #
  # `endpoint.config/1` reads the endpoint's ETS table, which exists only once
  # the endpoint has started. Everything that runs before that — the settings
  # cache warmer, other children started ahead of the endpoint, an Oban job
  # picked up at boot — and every node that never starts it (`mix run
  # --no-start`, a release `eval`, a one-off script) used to find no secret
  # here, resolve NO key, and treat every stored `enc:v1:` credential as
  # missing: an AI call went out without its API key and the provider answered
  # "invalid API key" for a key that is perfectly valid. The endpoint takes its
  # configuration from the host app's env, which is loaded (`runtime.exs`
  # included) before any application starts — so, unless the endpoint
  # defines `init/2` (see `configured_endpoint_secret/1`), the secret it will
  # run with is already there.
  defp endpoint_secret_key_base do
    case PhoenixKit.Config.get_parent_endpoint() do
      {:ok, endpoint} ->
        usable_secret(running_endpoint_secret(endpoint)) ||
          usable_secret(configured_endpoint_secret(endpoint))

      :error ->
        nil
    end
  rescue
    # A malformed `:parent_module` means no endpoint, hence no key — not a
    # crash in `status/0` or on a read.
    _ -> nil
  end

  defp running_endpoint_secret(endpoint) do
    endpoint.config(:secret_key_base)
  rescue
    # Loaded but not started: its config table does not exist yet.
    _ -> nil
  end

  # Phoenix still calls a deprecated `init/2` callback at start and runs with
  # the config it returns, so such an endpoint may run with a secret other than
  # its app env's. Reading the app env there would encrypt before start under
  # one key and decrypt after start under another; no key (plaintext writes,
  # the state before this lookup existed) is the safer answer.
  defp configured_endpoint_secret(endpoint) do
    cond do
      # `function_exported?/3` is false for a module not loaded yet.
      Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :init, 2) ->
        nil

      app = Application.get_application(endpoint) ->
        app |> Application.get_env(endpoint, []) |> Keyword.get(:secret_key_base)

      true ->
        nil
    end
  rescue
    # An endpoint env that is not a keyword list is not ours to interpret.
    _ -> nil
  end

  defp usable_secret(secret) when is_binary(secret) and secret != "", do: secret
  defp usable_secret(_other), do: nil

  # What an operator has to do when an `enc:v1:` value cannot be read because
  # no key resolves at all. Shared by the map path and the single-value path so
  # the two cannot give different advice about the same state.
  defp no_key_remedy do
    if encryption_enabled_flag?() do
      "No encryption key resolved: no `:integrations_encryption_key` (in config or a " <>
        "readable key store), no " <>
        "`config :phoenix_kit, :secret_key_base`, and no `secret_key_base` for the " <>
        "host endpoint (found through `config :phoenix_kit, :parent_module`). Set " <>
        "`config :phoenix_kit, secret_key_base: ...` in config/runtime.exs to the same " <>
        "value your Endpoint uses (or restore the `:integrations_encryption_key` the " <>
        "value was written under)."
    else
      "Integration encryption is switched off (`integration_encryption_enabled: false`), " <>
        "so stored encrypted values cannot be read; switch it back on to read them."
    end
  end

  # `decrypt_value/1` is called per read (settings, buckets) and its callers log
  # only the bare reason, so the remedy is logged here — once per VM, enough to
  # be found without repeating on every request.
  defp log_no_key_decrypt_once do
    key = {__MODULE__, :no_key_decrypt_logged}

    if :persistent_term.get(key, false) == false do
      :persistent_term.put(key, true)

      Logger.error(
        "[PhoenixKit.Integrations.Encryption] An encrypted value could not be decrypted " <>
          "(:encryption_unavailable) and is treated as missing. " <> no_key_remedy()
      )
    end

    :ok
  end

  defp derive_key(secret) do
    # Derive a dedicated 32-byte key for integration encryption
    :crypto.hash(:sha256, "phoenix_kit_integrations:" <> secret)
  end

  # ONE source for what falling off the dedicated tier actually costs, shared by
  # every surface that reports it. They used to phrase it separately, and the
  # per-read one stayed tier-blind after the boot one was fixed — so a single
  # run could emit two messages that contradicted each other about whether a
  # fallback key even existed. Deriving it in one place is what stops that
  # recurring.
  #
  # Reads `secret_key_base/0` rather than `status/0`: status resolves the tier,
  # which consults the store, which is what called this — that would recurse.
  # Derived from the status being described, NOT from a fresh look at the
  # environment. Reading the environment again is what produced the third
  # instance of this defect: a report built for the legacy tier asked the
  # environment, got a different answer, and announced "NO key resolved at all"
  # directly above a fingerprint of the key that had in fact resolved. A value
  # rendered from a state must not consult anything outside that state.
  # A third case, and the one this used to get wrong. The caller was described
  # as "the one caller that genuinely cannot be handed a status: it runs DURING
  # tier resolution, so asking for one would recurse", and it inferred the
  # consequence from `secret_key_base/0` alone. That inference has no way to
  # notice a dedicated key resolving from CONFIG, so an install with a working
  # dedicated key and a broken store was told at boot that "encryption fell back
  # to the secret_key_base-derived key" — the same false fallback claim this
  # module has now had removed from four other surfaces, sitting in the one
  # place that was exempted from the fix.
  #
  # The exemption was real but is no longer: since the resolution became a pure
  # function of three reads, the tier is known at the call site without a second
  # look at anything.
  # The tail of the boot line, for the same reason as the head: "repairing the
  # store later will not make anything written in the meantime readable" is
  # true only where writes are landing under a key the repair abandons. On the
  # dedicated tier nothing of the sort is happening.
  defp store_failure_urgency(:dedicated),
    do: "Fix the store so this key has a copy somewhere; nothing needs rewriting."

  defp store_failure_urgency(_tier),
    do:
      "Repairing the store later will not make anything written in the meantime readable. " <>
        "Fix the store before writing anything else."

  defp weaker_tier_consequence(:dedicated),
    do:
      "the key in use comes from configuration, so encryption itself is unaffected — but " <>
        "nothing is backing that key up"

  defp weaker_tier_consequence(:none),
    do: "NO key resolved at all — integration credentials are being written in PLAINTEXT"

  defp weaker_tier_consequence(:legacy),
    do:
      "encryption fell back to the secret_key_base-derived key, so values written under " <>
        "the stored key will not decrypt, and anything written now is encrypted under the " <>
        "fallback instead"
end
