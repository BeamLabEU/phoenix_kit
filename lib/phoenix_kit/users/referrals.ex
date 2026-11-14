defmodule PhoenixKit.Users.Referrals do
  @moduledoc """
  Core-side runtime bridge to the optional `phoenix_kit_referrals` package.

  The referral-codes feature lives in the standalone `phoenix_kit_referrals`
  module. Core has **no compile-time dependency** on it — this facade resolves
  the installed module at runtime by its `PhoenixKit.Module` key (`"referrals"`)
  via `PhoenixKit.ModuleRegistry` and dispatches through it.

  When the package isn't installed (or doesn't export a given function) every
  call degrades safely: the system reads as disabled, lookups return `nil`, and
  `use_code/2` is a no-op. That lets the registration / OAuth / magic-link flows
  treat referrals as optional — with the module absent, the referral field never
  appears and nothing is recorded.

  The function surface here mirrors exactly what the signup flows call, so those
  call sites only had to swap their alias to this module.

  ## Invite-only access gate

  With `referral_codes_required` on, a referral code is supposed to be the only
  way in. Enforcing that at each *creation* path does not work: OAuth and
  magic-link signups can be started from URLs that never pass through the
  registration form, and blocking them there produces dead ends rather than
  admission control.

  So enforcement is a **post-signup access gate**. An account may be created by
  any means; until it is *satisfied* it can reach nothing but
  `/users/referral` (where a code admits it) and log-out. `access_satisfied?/1`
  is the single predicate, called from the same choke points that enforce email
  confirmation — see `PhoenixKitWeb.Users.Auth`.

  An account is satisfied when any of these holds:

  1. It has `custom_fields["referral_satisfied_at"]` — written by
     `mark_satisfied/2` when a code is used at signup, entered on the parked
     screen, or accepted as part of an organization invitation.
  2. It was created before invite-only took effect and
     `referral_grandfather_existing` is on (the default). See below.
  3. It holds every enabled permission (`Scope.holds_all_enabled_permissions?/1`).
     This is a **hard exemption, independent of the grandfather setting** — an
     operator who turns grandfathering off on an install whose codes are all
     spent would otherwise lock themselves out with no way back in. It is keyed
     on permissions rather than a role name because that is what the rest of the
     admin gate uses, and Owner satisfies it by construction.
  4. A pending, unexpired organization invitation is addressed to its email.
     Invitations are email-bound, so this makes org admins de-facto admission
     issuers on purpose — without it the "you were invited" banner on the
     registration page is a dead end under invite-only.

  ### Why not `confirmed_at`

  The satisfied flag is deliberately independent of email confirmation. OAuth
  auto-confirms (`PhoenixKit.Users.OAuth`), so a gate keyed on `confirmed_at`
  would open for exactly the path it most needs to close.

  ### Grandfathering

  `referral_required_enabled_at` records when invite-only took effect, and users
  created before it are grandfathered while `referral_grandfather_existing`
  (default `true`) is on. Core stamps and clears that setting itself, from
  `access_required?/0`, rather than relying on the referrals admin toggle — that
  way it stays correct whoever flips the switch, including an older
  `phoenix_kit_referrals` that knows nothing about the gate. Turning invite-only
  off clears the stamp, so switching it on again grandfathers everyone admitted
  in between.

  ### If the package is uninstalled

  The gate requires `enabled?/0`, which goes through the installed module. With
  the package gone there is no way to *validate* a code, so gating on a
  left-behind `referral_codes_required` row would park every non-exempt user
  permanently.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Activity
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries, as: SettingsQueries
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @key "referrals"

  @doc "The `custom_fields` key recording that an account satisfied invite-only."
  def satisfied_field, do: "referral_satisfied_at"

  # Mirrors the key `phoenix_kit_referrals` writes. Read directly (rather than
  # through `get_config/0`) so the overwhelmingly common case — invite-only off
  # — costs one ETS-cached settings read instead of a module-registry scan.
  @required_setting "referral_codes_required"
  @required_since_setting "referral_required_enabled_at"
  @grandfather_setting "referral_grandfather_existing"
  @retention_setting "referral_unadmitted_retention_days"

  # One sweep's worth. The janitor runs daily, so a backlog drains over a few
  # days rather than deactivating thousands of accounts in a single statement
  # an operator cannot easily review or undo.
  @prune_batch_size 500

  # Shape core reads from `get_config/0` when no module is installed.
  @disabled_config %{enabled: false, required: false}

  # One message for every rejection. Distinct strings ("Invalid" vs "expired" vs
  # "usage limit") told an attacker whether a guessed code EXISTS, turning the
  # form into an enumeration oracle: existence and format confirmed for free.
  # Operators still get the real reason via `Logger.debug`.
  #
  # Messages are translated here, at the source, because every caller renders
  # them as given — the registration and magic-link forms print the string
  # straight into the page, so an untranslated one shows up in English on a site
  # in any other language. A function, not a module attribute: the locale is a
  # property of the calling process, so it has to be read per call.
  defp rejection_message, do: gettext("That code can't be used")

  @doc """
  Referral-codes configuration map. Disabled defaults when the module is absent.
  """
  def get_config do
    case dispatch(:get_config, []) do
      {:ok, config} -> config
      :error -> @disabled_config
    end
  end

  @doc "Whether a referrals module is installed and enabled."
  def enabled? do
    get_config()[:enabled] == true
  end

  @doc "Look up a referral code struct by its string, or `nil`."
  def get_code_by_string(code_string) do
    case dispatch(:get_code_by_string, [code_string]) do
      {:ok, code} -> code
      :error -> nil
    end
  end

  @doc """
  Whether the given code is expired.

  ⚠️ Answers **`true`** when nothing can answer. These predicates gate admission
  under invite-only, so "we could not check" has to mean "do not admit" — the
  old `false` default let a code past an expiry check that never ran.
  """
  def expired?(code) do
    case dispatch(:expired?, [code]) do
      {:ok, result} -> result
      :error -> true
    end
  end

  @doc "Whether the given code hit its usage limit. Fails closed — see `expired?/1`."
  def usage_limit_reached?(code) do
    case dispatch(:usage_limit_reached?, [code]) do
      {:ok, result} -> result
      :error -> true
    end
  end

  @doc """
  Record a use of `code_string` by `user_uuid`.

  No-op returning `{:error, :referrals_not_installed}` when the module is absent.
  """
  def use_code(code_string, user_uuid) do
    case dispatch(:use_code, [code_string, user_uuid]) do
      {:ok, result} -> result
      :error -> {:error, :referrals_not_installed}
    end
  end

  @doc """
  Validates a referral code for a signup attempt.

  Shared by every signup surface so the rules cannot drift apart — the password
  and magic-link forms previously carried byte-identical private copies.

  ## Options

  - `:enabled?` / `:required?` — from `get_config/0` (required)
  - `:context` — `:change` while the user types, `:submit` on the final attempt
  - `:ip_address` — used to rate-limit code checking; omit and no limit applies

  ## Why `:context` matters

  On `:change`, **nothing is rejected**. Validation runs on every keystroke
  anywhere in the form, so treating blank-and-required as invalid made "Referral
  code is required" appear while the user was still typing their email — before
  they had reached the field. `:submit` enforces presence.

  A typed code is not checked on change either, which reverses an earlier
  decision that a touched field was fair to complain about. Two reasons pointing
  the same way: checking per keystroke hands an attacker a far faster oracle
  than the submit button does, and it spends one rate-limit token per character,
  so a real person typing an eight-character code and fixing a typo can exhaust
  their own budget while holding a good code.

  ## Why rejections are indistinguishable

  Every failure returns the same message. Separate strings for
  missing / inactive / expired / limit-reached confirmed which guesses named a
  real code. The specific reason is logged at debug level for operators.

  Returns `{:ok, code_or_nil}` or `{:error, message}`.
  """
  def validate_for_signup(code, opts) do
    enabled? = Keyword.fetch!(opts, :enabled?)
    required? = Keyword.fetch!(opts, :required?)
    context = Keyword.get(opts, :context, :submit)
    trimmed = code |> to_string() |> String.trim()

    cond do
      not enabled? ->
        {:ok, nil}

      trimmed == "" and required? and context == :submit ->
        {:error, gettext("Referral code is required")}

      trimmed == "" ->
        # Blank and either optional, or still being filled in.
        {:ok, nil}

      context == :change ->
        # A typed code is NOT checked while the user is still typing. Two
        # reasons, and they point the same way: checking per keystroke hands an
        # attacker a much faster oracle than the submit button does, and it
        # spends one rate-limit token per character — so a real person typing an
        # 8-character code and correcting a typo can exhaust their own budget and
        # be told "too many attempts" while holding a perfectly good code.
        {:ok, nil}

      true ->
        validate_typed_code(trimmed, Keyword.get(opts, :ip_address))
    end
  end

  defp validate_typed_code(code_string, ip_address) do
    case rate_limit_check(ip_address) do
      :ok ->
        check_code(code_string)

      {:error, :rate_limit_exceeded} ->
        {:error, gettext("Too many attempts. Please try again shortly.")}
    end
  end

  defp rate_limit_check(ip) when is_binary(ip),
    do: RateLimiter.check_referral_validation_rate_limit(ip)

  defp rate_limit_check(_), do: :ok

  defp check_code(code_string) do
    case get_code_by_string(code_string) do
      nil ->
        reject(code_string, "no such code")

      code ->
        cond do
          not code.status -> reject(code_string, "code is inactive")
          expired?(code) -> reject(code_string, "code has expired")
          usage_limit_reached?(code) -> reject(code_string, "code hit its usage limit")
          true -> {:ok, code}
        end
    end
  end

  defp reject(code_string, reason) do
    Logger.debug("[Referrals] rejected #{inspect(code_string)}: #{reason}")
    {:error, rejection_message()}
  end

  # ============================================================================
  # Invite-only access gate — see the "Invite-only access gate" moduledoc section
  # ============================================================================

  @doc """
  Whether invite-only enforcement is currently active.

  Also keeps `referral_required_enabled_at` in step with the answer, so the
  grandfather boundary always describes the *current* invite-only period.
  """
  @spec access_required?() :: boolean()
  def access_required? do
    # Fast path first: `referral_codes_required` is a plain settings row, so an
    # install that never turned invite-only on stops after one cached read.
    # `enabled?/0` behind it is the authority — it goes through the installed
    # module, and without the module a code cannot be validated at all.
    setting_on? = Settings.get_boolean_setting(@required_setting, false)

    # The boundary tracks the SETTING, not the gate. Keying it on the gate would
    # clear the stamp whenever the package is briefly unresolvable — a deploy
    # without the dependency, a registry miss — and the re-stamp on recovery
    # reads `date_updated`, which any unrelated settings save in the meantime
    # will have moved forward, grandfathering accounts that registered under
    # invite-only.
    sync_required_since(setting_on?)

    setting_on? and enabled?()
  end

  @doc """
  Whether this account may use the application, or must first enter a code.

  Accepts a `Scope` or a `User`; anything else (including `nil`) is satisfied,
  because deciding admission for a visitor with no account is the
  authentication gate's job, not this one.

  The `User` form exists for the older user-based `on_mount` hook, which has no
  scope. It has to build one to evaluate the full-access exemption, so it is
  the more expensive form — but only for an account that is not already
  satisfied on cheaper grounds.
  """
  @spec access_satisfied?(Scope.t() | User.t() | nil) :: boolean()
  def access_satisfied?(subject) do
    not access_required?() or satisfied_by_account?(subject)
  end

  defp satisfied_by_account?(%Scope{user: %User{} = user} = scope) do
    marked_satisfied?(user) or grandfathered?(user) or
      Scope.holds_all_enabled_permissions?(scope) or invited?(user) or
      historically_redeemed?(user)
  end

  defp satisfied_by_account?(%User{} = user) do
    # Permission check goes last here: unlike the scope form it costs a DB read.
    marked_satisfied?(user) or grandfathered?(user) or invited?(user) or
      Scope.holds_all_enabled_permissions?(Scope.for_user(user)) or
      historically_redeemed?(user)
  end

  defp satisfied_by_account?(_), do: true

  # An account that redeemed a code under referrals 0.4 has a usage row but no
  # satisfied-stamp — the stamp arrived with 0.6's flows, and the upgrade path
  # never backfilled it, so the gate parked exactly the users who did what
  # invite-only asked of them. The installed module answers from its usage
  # table, and a hit is stamped on the spot, so for any given account this
  # dispatch-plus-query runs at most once. Last in the chain: every earlier
  # check is cheaper, and post-0.6 accounts never reach it.
  defp historically_redeemed?(%User{} = user) do
    case dispatch(:signup_use_exists?, [user.uuid]) do
      {:ok, true} ->
        mark_satisfied(user, "pre-0.6 code redemption (lazy backfill)")
        true

      _ ->
        false
    end
  end

  @doc """
  Records a signup's use of a referral code and marks the account admitted.

  The two halves belong together. `use_code/2` on its own leaves an account
  that supplied a perfectly good code sitting behind the invite-only gate —
  the exact opposite of what supplying it meant — and every signup path had
  its own copy of the first half only.

  Accepts the code as a string or as an already-resolved code struct; `nil`
  (no code supplied) is a no-op. Marking happens even when invite-only is
  currently off, so an operator who turns it on later does not park the people
  who did bring a code.
  """
  @spec record_signup_use(User.t(), String.t() | map() | nil) :: :ok
  def record_signup_use(_user, nil), do: :ok

  def record_signup_use(%User{} = user, code_string) when is_binary(code_string) do
    # ⚠️ VALIDATE, do not merely look up. The OAuth path passes a raw string
    # straight from the session, and a bare `get_code_by_string/1` finds
    # inactive, expired and exhausted codes just as happily as live ones — which
    # under the access gate would ADMIT an account on a code that can never be
    # used. `check_code/1` is the same predicate the signup forms go through.
    case check_code(code_string) do
      {:ok, code} ->
        record_signup_use(user, code)

      {:error, _message} ->
        Logger.debug("[Referrals] signup code #{inspect(code_string)} not usable; not recording")
        :ok
    end
  end

  def record_signup_use(%User{} = user, %{code: code_string}) do
    case redeem(user, code_string) do
      {:ok, _user} ->
        :ok

      {:error, reason} ->
        # A claim lost to a concurrent user, or a write failure. Admission must
        # NOT follow: marking anyway would let a code past its usage limit
        # admit every racer that tried for it.
        Logger.warning("[Referrals] could not redeem #{inspect(code_string)}: #{inspect(reason)}")
        :ok
    end
  end

  def record_signup_use(_user, _code), do: :ok

  @doc """
  Claims one use of `code_string` for `user` and marks the account admitted,
  atomically.

  The two writes have to succeed or fail together. Claiming without marking
  burns a use of a possibly single-use code and leaves the user still parked,
  with the same code now rejecting them; marking without claiming lets a code
  past its limit admit everyone who raced for it.

  Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec redeem(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def redeem(%User{} = user, code_string) when is_binary(code_string) do
    RepoHelper.repo().transaction(fn ->
      # Already admitted: `mark_satisfied/2` would answer `{:ok, user}` and the
      # claim would still commit, so a duplicate call — a resubmitted form, a
      # signup that also accepted an invitation — silently spends a use of a
      # limited code and buys nothing.
      if marked_satisfied?(user) do
        user
      else
        with {:ok, _usage} <- use_code(code_string, user.uuid),
             {:ok, updated} <- mark_satisfied(user, "code") do
          updated
        else
          {:error, reason} -> RepoHelper.repo().rollback(reason)
        end
      end
    end)
  end

  @doc """
  Records that an account has satisfied invite-only, and why.

  Idempotent: an already-marked account keeps its original timestamp, so a
  second call cannot rewrite when admission happened. `reason` is stored
  alongside for operators auditing how an account got in.
  """
  @spec mark_satisfied(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def mark_satisfied(%User{} = user, reason) when is_binary(reason) do
    if marked_satisfied?(user) do
      {:ok, user}
    else
      # `merge_user_custom_fields/3` merges inside the UPDATE, so this cannot
      # clobber a concurrent writer of a different custom_fields key.
      Auth.merge_user_custom_fields(
        user,
        %{
          satisfied_field() => DateTime.to_iso8601(UtilsDate.utc_now()),
          "referral_satisfied_via" => reason
        },
        ensure_definitions: false
      )
    end
  end

  def mark_satisfied(_user, _reason), do: {:error, :not_a_user}

  @doc "Whether this account has already been marked as satisfying invite-only."
  @spec marked_satisfied?(User.t() | nil) :: boolean()
  def marked_satisfied?(%User{custom_fields: fields}) when is_map(fields) do
    case fields[satisfied_field()] do
      value when is_binary(value) -> value != ""
      _ -> false
    end
  end

  def marked_satisfied?(_), do: false

  # An account created before invite-only took effect, while the operator has
  # left grandfathering on. Deliberately re-evaluated on every request rather
  # than persisted: turning `referral_grandfather_existing` off is meant to park
  # exactly these accounts, which a one-time mark would defeat.
  defp grandfathered?(%User{inserted_at: created_at}) do
    Settings.get_boolean_setting(@grandfather_setting, true) and
      created_before?(created_at, required_since())
  end

  # At-or-before, not strictly before. Both timestamps are second precision, so
  # an account that was already in the database when the operator flipped the
  # switch usually reads as the same second — and parking a user who was
  # demonstrably already signed up is the worse error of the two. The cost is a
  # one-second window in which a new signup is grandfathered.
  #
  # `inserted_at` is `:utc_datetime` on core's own User schema, but this
  # normalizes anyway: a silent `false` here does not fail visibly — it disables
  # grandfathering for everyone and hands the janitor a list of accounts to
  # deactivate. The other half of this comparison already normalizes, and
  # holding the two to different standards is how that goes unnoticed.
  defp created_before?(created_at, %DateTime{} = since) do
    case as_utc(created_at) do
      %DateTime{} = at -> DateTime.compare(at, since) != :gt
      nil -> false
    end
  end

  # No boundary recorded yet: nobody is grandfathered.
  defp created_before?(_created_at, _since), do: false

  defp as_utc(%DateTime{} = datetime), do: datetime
  defp as_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp as_utc(_), do: nil

  # A pending, unexpired organization invitation addressed to this account.
  defp invited?(%User{email: email}) do
    Invitations.list_pending_for_email(email) != []
  rescue
    # A gate that crashes locks users out of the whole application, so fail to
    # "not invited" and let the other checks decide. Also covers an email-less
    # struct, which `list_pending_for_email/1`'s guard rejects.
    error ->
      Logger.warning("[Referrals] invitation check failed: #{Exception.message(error)}")
      false
  catch
    # This one is a real query, not a settings read, so it is the clause that
    # matters most here: an unreachable database raises on an unowned checkout
    # but *exits* on a dead pool. With only the `rescue`, the exit escapes and
    # takes down every gated page — the site-wide lockout the rescue was added
    # to prevent, just via the failure mode nobody reproduces locally.
    :exit, _reason ->
      Logger.warning("[Referrals] invitation check failed: database unavailable")
      false
  end

  @doc """
  How long an unadmitted account is left alone before the janitor deactivates
  it, in days. `0` (the default) means never.

  Deliberately opt-in. The alternative — a default that silently starts
  deactivating accounts as soon as an operator switches invite-only on — is the
  kind of destructive default that has to be asked for, not inherited.
  """
  @spec unadmitted_retention_days() :: non_neg_integer()
  def unadmitted_retention_days do
    Settings.get_integer_setting(@retention_setting, 0)
  end

  @doc """
  Deactivates accounts that were created under invite-only and never satisfied
  it, so "registered" keeps meaning "admitted".

  **Deactivates; never deletes.** Users are the foreign-key target of most of
  the ecosystem, and an account that was merely slow to enter its code is one
  an operator will want back.

  Nothing happens unless invite-only is on AND `days` is positive — an install
  that turned invite-only off should not have the janitor sweeping up the
  accounts it just legitimised. Candidates are re-checked one by one through
  `access_satisfied?/1` rather than trusted from the query, because the
  exemptions that matter most (full permissions, a pending invitation) are the
  ones SQL cannot see.

  Returns `{:ok, count}`.
  """
  @spec prune_unadmitted(non_neg_integer()) :: {:ok, non_neg_integer()}
  def prune_unadmitted(days) when is_integer(days) and days > 0 do
    if access_required?() do
      count =
        days
        |> prune_candidates()
        |> Enum.reject(&access_satisfied?/1)
        |> Enum.count(&deactivate_unadmitted/1)

      {:ok, count}
    else
      {:ok, 0}
    end
  end

  def prune_unadmitted(_days), do: {:ok, 0}

  @doc """
  One sweep's worth of rows, before the per-account authority check.

  Separated from `prune_unadmitted/1` so the grandfather exclusion can be
  asserted directly. Testing it through the sweep would take
  `#{@prune_batch_size}` accounts to demonstrate — the starvation it prevents
  only appears once exempt rows can fill the batch — and a suite that registers
  five hundred users to prove one `WHERE` clause is a suite nobody runs.
  """
  @spec prune_candidates(pos_integer()) :: [User.t()]
  def prune_candidates(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(UtilsDate.utc_now(), -days * 86_400, :second)

    from(u in User,
      where: u.is_active == true,
      where: u.inserted_at < ^cutoff,
      # Cheap pre-filter only. The authority is `access_satisfied?/1`.
      where: fragment("COALESCE(?->>?, '') = ''", u.custom_fields, ^satisfied_field()),
      order_by: [asc: u.inserted_at],
      limit: @prune_batch_size
    )
    |> exclude_grandfathered()
    |> RepoHelper.repo().all()
  end

  # Grandfathered accounts are permanently exempt AND permanently match the
  # pre-filter above: they carry no satisfied stamp and never will, because
  # grandfathering is re-evaluated per request rather than written down.
  #
  # That combination starves the sweep. Grandfathering means "created at or
  # before the boundary", so grandfathered accounts are exactly the OLDEST rows
  # — and the batch is ordered oldest-first. Left in, they fill all
  # `@prune_batch_size` slots, `access_satisfied?/1` rejects every one, and the
  # janitor deactivates nobody, every day, forever. It fails on precisely the
  # install it exists for: an established site with more than a batch of
  # existing users that has just switched invite-only on.
  #
  # This is the same predicate `grandfathered?/1` applies per account, pushed
  # into SQL so exempt rows never occupy the batch. The per-account re-check
  # still has the last word — the exemptions SQL cannot see (full permissions, a
  # pending invitation) are why it is the authority.
  defp exclude_grandfathered(query) do
    with true <- Settings.get_boolean_setting(@grandfather_setting, true),
         %DateTime{} = since <- required_since() do
      from(u in query, where: u.inserted_at > ^since)
    else
      # Grandfathering off, or no boundary recorded — nobody is exempt on age,
      # so there is nothing to exclude.
      _ -> query
    end
  end

  defp deactivate_unadmitted(%User{} = user) do
    case Auth.update_user_status(user, %{"is_active" => false}) do
      {:ok, _user} ->
        log_deactivation(user)
        true

      {:error, reason} ->
        # `:cannot_deactivate_last_owner` lands here, and so does a plain
        # changeset failure. Neither is worth aborting the sweep over.
        Logger.warning("[Referrals] could not deactivate #{user.uuid}: #{inspect(reason)}")
        false
    end
  end

  # The account is already deactivated by the time this runs, so a failure here
  # must not raise: it would abort the remaining candidates AND make Oban retry
  # the whole batch against accounts it has already deactivated.
  defp log_deactivation(user) do
    Activity.log(%{
      action: "user.deactivated",
      module: "users",
      mode: "cron",
      resource_type: "user",
      resource_uuid: user.uuid,
      target_uuid: user.uuid,
      metadata: %{"reason" => "referral_never_satisfied", "actor_role" => "system"}
    })
  rescue
    error ->
      Logger.warning("[Referrals] could not log deactivation: #{Exception.message(error)}")
      :ok
  catch
    # Same reasoning as the rescue, same blast radius: an exit here aborts the
    # remaining candidates and makes Oban retry the whole batch against accounts
    # it has already deactivated.
    :exit, _reason ->
      Logger.warning("[Referrals] could not log deactivation: database unavailable")
      :ok
  end

  defp required_since do
    case Settings.get_setting_cached(@required_since_setting) do
      value when is_binary(value) and value != "" ->
        case DateTime.from_iso8601(value) do
          {:ok, stamped_at, _offset} -> stamped_at
          {:error, _} -> nil
        end

      _ ->
        nil
    end
  end

  # Stamps the setting when invite-only goes on and clears it when it goes off.
  # Both reads are ETS-cached (misses included), so the steady state is two
  # lookups; the write only fires on an actual transition. Concurrent writers
  # during a transition settle on timestamps milliseconds apart, which is inside
  # the resolution the boundary is meaningful at.
  defp sync_required_since(true) do
    if is_nil(required_since()) do
      stamp(@required_since_setting, DateTime.to_iso8601(fallback_boundary()))
    end

    :ok
  end

  defp sync_required_since(false) do
    if required_since(), do: stamp(@required_since_setting, nil)
    :ok
  end

  # When core has to stamp the boundary itself, "now" is the wrong answer: this
  # runs on the first GATED REQUEST after the flip, not at the flip, and every
  # account created in between would be grandfathered — admitted with no code on
  # an install that had already gone invite-only. On a quiet site that window can
  # be hours.
  #
  # The `referral_codes_required` row's own `date_updated` is when the switch
  # was actually thrown, so use it. One uncached read, on a path that runs at most
  # once per invite-only period, and it falls back to now if the row cannot be
  # read (better a boundary that is slightly late than none at all, which would
  # park every existing user).
  defp fallback_boundary do
    case SettingsQueries.get_setting_by_key(@required_setting) do
      %{date_updated: at} -> as_utc(at) || UtilsDate.utc_now()
      _ -> UtilsDate.utc_now()
    end
  rescue
    _ -> UtilsDate.utc_now()
  catch
    # Uncached read on the authentication path — see `stamp/2` below for why
    # both clauses are needed. Without this one a dead pool exits through
    # `access_required?/0` and every gated page goes with it.
    :exit, _reason -> UtilsDate.utc_now()
  end

  # This runs on the authentication path, so a settings write that fails must
  # not take the site down with it. An unreachable database raises on an unowned
  # checkout but *exits* on a dead pool, hence both clauses. The consequence of
  # skipping a stamp is a grandfather boundary that settles on the next request.
  defp stamp(key, value) do
    Settings.update_setting(key, value)
  rescue
    error ->
      Logger.warning("[Referrals] could not update #{key}: #{Exception.message(error)}")
      :error
  catch
    :exit, _reason ->
      Logger.warning("[Referrals] could not update #{key}: database unavailable")
      :error
  end

  # Resolve the installed referrals module by key and call it. Returns
  # `{:ok, result}` or `:error` when nothing handles it. `apply/3` keeps the
  # target out of compile-time xref, so core needs no dependency on the package.
  defp dispatch(fun, args) do
    with mod when not is_nil(mod) <- ModuleRegistry.get_by_key(@key),
         true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, fun, length(args)) do
      {:ok, apply(mod, fun, args)}
    else
      _ -> :error
    end
  rescue
    # This now runs on the authentication path, so a raise inside the installed
    # package would take every gated page down with it. `:error` is what an
    # absent module returns, and every caller already has a safe answer for it —
    # which for the admission predicates means failing closed.
    error ->
      Logger.warning("[Referrals] #{fun}/#{length(args)} failed: #{Exception.message(error)}")
      :error
  catch
    :exit, _reason ->
      Logger.warning("[Referrals] #{fun}/#{length(args)} failed: process exited")
      :error
  end
end
