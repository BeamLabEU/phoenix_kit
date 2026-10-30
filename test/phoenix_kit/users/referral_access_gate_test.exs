defmodule PhoenixKit.Users.ReferralAccessGateTest do
  @moduledoc """
  Covers the invite-only access gate — `Referrals.access_satisfied?/1` and the
  state it derives that answer from.

  Invite-only used to be enforced only on the password registration form, so
  the same install let anyone in through OAuth or a magic link. Enforcement
  moved to a post-signup gate; these tests pin the parts of it that are easy to
  get subtly wrong and impossible to notice from the outside — an account
  silently admitted, or an operator silently locked out.

  `phoenix_kit_referrals` is not a dependency of core, so the "invite-only is
  actually on" cases register a stub module under the `"referrals"` key. That
  is not a shortcut: the gate deliberately reads *through* the installed
  module, and one of the tests below is about what happens when there isn't one.
  """
  use PhoenixKit.DataCase, async: false

  # These tests assert BOOTSTRAP semantics (first-user-becomes-Owner, last-
  # Owner guards, owner counts), so the suite's committed seed Owner is
  # demoted inside this test's own sandbox transaction — see DataCase.
  setup {PhoenixKit.DataCase, :demote_seed_owner}

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: Fixtures
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Users.Roles

  defmodule EnabledReferrals do
    @moduledoc false
    def module_key, do: "referrals"
    def get_config, do: %{enabled: true, required: true}
  end

  defmodule ReferralsWithHistoricalUse do
    @moduledoc false
    def module_key, do: "referrals"
    def get_config, do: %{enabled: true, required: true}
    # Every account "has" a 0.4-era usage row.
    def signup_use_exists?(_user_uuid), do: true
  end

  setup do
    on_exit(fn ->
      ModuleRegistry.unregister(EnabledReferrals)
      Settings.update_setting("referral_codes_required", "false")
      Settings.update_setting("referral_grandfather_existing", "true")
      Settings.update_setting("referral_required_enabled_at", nil)
    end)

    # The sandbox starts with an empty users table, and `register_user/2`
    # promotes the FIRST account to Owner. Owner satisfies the full-access
    # exemption, so without this every "should be parked" assertion would pass
    # for the wrong reason. Registering it up front also gives the exemption
    # tests a genuinely privileged account to use.
    %{owner: register_user()}
  end

  # Turns invite-only on. `boundary` overrides the auto-stamped grandfather
  # cutoff — both it and `inserted_at` are second precision, so tests that care
  # which side of it a user falls on have to say, rather than race the clock and
  # be flaky whenever the two land in the same second. The auto-stamp itself is
  # covered separately below.
  defp enable_invite_only(boundary \\ nil) do
    ModuleRegistry.register(EnabledReferrals)
    Settings.update_setting("referral_codes_required", "true")
    # Reading the gate is what stamps the boundary.
    true = Referrals.access_required?()

    if boundary do
      Settings.update_setting("referral_required_enabled_at", DateTime.to_iso8601(boundary))
    end

    :ok
  end

  # A cutoff every account in the test was created *after* — nobody is
  # grandfathered.
  defp long_ago, do: DateTime.add(DateTime.utc_now(), -3600, :second)

  # A cutoff every account in the test was created *before* — everybody is.
  defp later_today, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  defp register_user(attrs \\ %{}) do
    email = "gate-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      Auth.register_user(Map.merge(%{email: email, password: "ValidPassword123!"}, attrs))

    user
  end

  describe "when invite-only is off" do
    test "every account is satisfied, and nothing is stamped" do
      user = register_user()

      assert Referrals.access_satisfied?(user)
      assert Referrals.access_satisfied?(Scope.for_user(user))
      refute Referrals.access_required?()
      assert Settings.get_setting_cached("referral_required_enabled_at") in [nil, ""]
    end
  end

  describe "when the setting is on but the package is not installed" do
    test "the gate stays off rather than locking everyone out" do
      # Without the module there is no way to VALIDATE a code, so a left-behind
      # `referral_codes_required` row would park every non-exempt user on a
      # screen that can never accept anything they type.
      Settings.update_setting("referral_codes_required", "true")

      refute Referrals.access_required?()
      assert Referrals.access_satisfied?(register_user())
    end
  end

  describe "when invite-only is on" do
    test "a dedicated managed organization is admitted without granting privileged roles", %{
      owner: owner
    } do
      :ok = enable_invite_only(long_ago())
      manager = Fixtures.person()
      refute Referrals.access_satisfied?(manager)
      {:ok, owner} = Auth.admin_confirm_user(owner)
      {token, _} = Fixtures.session(owner)
      {:ok, actor} = Actor.from_session(%{"user_token" => token})

      assert {:ok, org} =
               ManagedOrganizations.create(
                 actor,
                 %{organization_name: "Invite-only Co"},
                 manager.uuid
               )

      assert Referrals.marked_satisfied?(org)
      assert Referrals.access_satisfied?(Scope.for_user(org))
      assert Roles.get_user_roles(org) == ["User"]
    end

    test "an account created after it took effect is not satisfied" do
      user = register_user()
      :ok = enable_invite_only(long_ago())

      refute Referrals.access_satisfied?(user)
      refute Referrals.access_satisfied?(Scope.for_user(user))
    end

    test "an account created before it took effect is grandfathered" do
      user = register_user()
      :ok = enable_invite_only(later_today())

      assert Referrals.access_satisfied?(user)
    end

    test "turning grandfathering off parks those same accounts" do
      user = register_user()
      :ok = enable_invite_only(later_today())
      Settings.update_setting("referral_grandfather_existing", "false")

      refute Referrals.access_satisfied?(user)
    end

    test "a marked account is satisfied" do
      user = register_user()
      :ok = enable_invite_only(long_ago())

      {:ok, marked} = Referrals.mark_satisfied(user, "code")

      assert Referrals.access_satisfied?(marked)
      assert Referrals.marked_satisfied?(marked)
    end

    test "a pending invitation admits the account it names" do
      org = register_user(%{account_type: "organization", organization_name: "Acme"})
      invited = register_user()
      :ok = enable_invite_only(long_ago())

      refute Referrals.access_satisfied?(invited)

      {:ok, _invitation, _token} = Invitations.create_invitation(org, invited.email, org)

      assert Referrals.access_satisfied?(Auth.get_user(invited.uuid))
    end

    test "an invitation is not consumed when admission cannot be recorded" do
      # The gate reads PENDING invitations, so acceptance removes the very thing
      # admitting this user. Marking first is not enough on its own — accepting
      # anyway after a failed mark still strands them: invitation gone, mark
      # absent, nothing left that can satisfy the gate.
      :ok = enable_invite_only(long_ago())
      org = register_user(%{account_type: "organization", organization_name: "Acme"})
      invited = register_user()

      {:ok, invitation, _token} = Invitations.create_invitation(org, invited.email, org)

      # A user struct that no longer matches a row: the merge finds nothing to
      # update, so `mark_satisfied/2` fails the way a stale struct would.
      ghost = %{invited | uuid: "019fc487-0000-7000-8000-00000000dead"}

      assert {:error, {:could_not_record_admission, _}} =
               Invitations.accept_invitation_by_uuid(invitation.uuid, ghost)

      # Still pending, so the real user is still admitted.
      assert Invitations.list_pending_for_email(invited.email) != []
      assert Referrals.access_satisfied?(Auth.get_user(invited.uuid))
    end

    test "accepting that invitation keeps the account admitted" do
      # The gate reads *pending* invitations, so acceptance removes the very
      # thing admitting this user — they are marked BEFORE it is consumed, or a
      # failed mark would strand them with nothing left to satisfy the gate.
      org = register_user(%{account_type: "organization", organization_name: "Acme"})
      invited = register_user()
      :ok = enable_invite_only(long_ago())

      {:ok, invitation, _token} = Invitations.create_invitation(org, invited.email, org)
      {:ok, _} = Invitations.accept_invitation_by_uuid(invitation.uuid, invited)

      reloaded = Auth.get_user(invited.uuid)
      assert Referrals.marked_satisfied?(reloaded)
      assert Referrals.access_satisfied?(reloaded)
    end
  end

  describe "the full-access exemption" do
    test "holds even with grandfathering off", %{owner: owner} do
      # The lockout this prevents: an operator turns grandfathering off on an
      # install whose codes are all spent, and has no way back into their own
      # admin panel.
      :ok = enable_invite_only(long_ago())
      Settings.update_setting("referral_grandfather_existing", "false")

      scope = Scope.for_user(Auth.get_user(owner.uuid))
      assert Scope.holds_all_enabled_permissions?(scope)
      assert Referrals.access_satisfied?(scope)
    end

    test "the user form reaches the same answer without a prebuilt scope", %{owner: owner} do
      # The older user-based on_mount hook has no scope, so this clause has to
      # build one — an account that is exempt through one entry point must not
      # be parked through the other.
      :ok = enable_invite_only(long_ago())
      Settings.update_setting("referral_grandfather_existing", "false")

      assert Referrals.access_satisfied?(Auth.get_user(owner.uuid))
    end
  end

  describe "the grandfather boundary stamp" do
    test "is written when invite-only goes on and cleared when it goes off" do
      :ok = enable_invite_only()
      stamped = Settings.get_setting_cached("referral_required_enabled_at")
      assert {:ok, _dt, _} = DateTime.from_iso8601(stamped)

      Settings.update_setting("referral_codes_required", "false")
      refute Referrals.access_required?()

      assert Settings.get_setting_cached("referral_required_enabled_at") in [nil, ""]
    end

    test "is not moved by later reads" do
      # Re-stamping on every request would walk the boundary forward and park
      # accounts that were grandfathered a moment earlier.
      :ok = enable_invite_only()
      first = Settings.get_setting_cached("referral_required_enabled_at")

      assert Referrals.access_required?()
      assert Referrals.access_required?()

      assert Settings.get_setting_cached("referral_required_enabled_at") == first
    end
  end

  describe "mark_satisfied/2" do
    test "records when and how, and never rewrites either" do
      user = register_user()

      {:ok, marked} = Referrals.mark_satisfied(user, "code")
      first_at = marked.custom_fields["referral_satisfied_at"]
      assert marked.custom_fields["referral_satisfied_via"] == "code"

      {:ok, again} = Referrals.mark_satisfied(marked, "invitation")

      assert again.custom_fields["referral_satisfied_at"] == first_at
      assert again.custom_fields["referral_satisfied_via"] == "code"
    end

    test "leaves other custom_fields alone" do
      user = register_user()
      {:ok, user} = Auth.merge_user_custom_fields(user, %{"preferred_locale" => "et"})

      {:ok, marked} = Referrals.mark_satisfied(user, "code")

      assert marked.custom_fields["preferred_locale"] == "et"
    end
  end

  describe "record_signup_use/2" do
    test "a nil code is a no-op" do
      user = register_user()
      assert :ok = Referrals.record_signup_use(user, nil)
      refute Referrals.marked_satisfied?(Auth.get_user(user.uuid))
    end

    test "a code string that cannot be validated admits nobody" do
      # ⚠️ The OAuth path hands this a raw string straight from the session and
      # never validates it. A bare lookup finds inactive, expired and exhausted
      # codes just as happily as live ones — so admitting on a lookup alone
      # would let a dead code get an account past invite-only.
      #
      # With the referrals package absent no code is usable, which is the shape
      # this asserts.
      user = register_user()

      assert :ok = Referrals.record_signup_use(user, "SOME-DEAD-CODE")

      refute Referrals.marked_satisfied?(Auth.get_user(user.uuid))
    end

    test "a failed claim does not mark the account" do
      # `use_code/2` can lose a race for the last remaining use. Marking anyway
      # would let one code admit every account that raced for it.
      user = register_user()

      assert :ok = Referrals.record_signup_use(user, %{code: "WELCOME"})

      refute Referrals.marked_satisfied?(Auth.get_user(user.uuid))
    end
  end

  describe "the admission predicates fail closed" do
    test "an unanswerable expiry check reads as expired, not as fresh" do
      # These gate admission now. "We could not check" has to mean "do not
      # admit" — defaulting to false let a code past an expiry check that never
      # ran. With no package installed nothing can answer.
      assert Referrals.expired?(%{code: "ANY"})
      assert Referrals.usage_limit_reached?(%{code: "ANY"})
    end
  end

  describe "redeem/2" do
    test "an already-admitted account does not spend a code" do
      # `mark_satisfied/2` is idempotent and would return {:ok, user}, so
      # without a check the claim still commits — a resubmitted form or a signup
      # that also accepted an invitation silently burns a use of a limited code
      # and buys nothing.
      user = register_user()
      {:ok, marked} = Referrals.mark_satisfied(user, "invitation")

      assert {:ok, _user} = Referrals.redeem(marked, "WELCOME")

      # Still marked by the ORIGINAL reason: nothing was re-recorded.
      assert Auth.get_user(user.uuid).custom_fields["referral_satisfied_via"] == "invitation"
    end

    test "claim and mark are one transaction" do
      # Neither half may land alone: claiming without marking burns a use of a
      # possibly single-use code and leaves the user parked with a code that now
      # rejects them; marking without claiming lets an exhausted code admit
      # everyone who raced for it.
      user = register_user()

      # No referrals package is installed, so the claim cannot succeed.
      assert {:error, _reason} = Referrals.redeem(user, "WELCOME")
      refute Referrals.marked_satisfied?(Auth.get_user(user.uuid))
    end
  end

  describe "prune_unadmitted/1" do
    test "does nothing at the default retention" do
      user = register_user()
      :ok = enable_invite_only(long_ago())

      assert {:ok, 0} = Referrals.prune_unadmitted(Referrals.unadmitted_retention_days())
      assert Auth.get_user(user.uuid).is_active
    end

    test "does nothing while invite-only is off, however long the retention" do
      # An install that just legitimised these accounts by turning invite-only
      # off must not then have them swept up.
      user = register_user()

      assert {:ok, 0} = Referrals.prune_unadmitted(1)
      assert Auth.get_user(user.uuid).is_active
    end

    test "leaves accounts that are inside the retention window alone" do
      user = register_user()
      :ok = enable_invite_only(long_ago())

      assert {:ok, 0} = Referrals.prune_unadmitted(30)
      assert Auth.get_user(user.uuid).is_active
    end
  end

  describe "prune_candidates/1" do
    @describetag :prune_starvation_guard

    # ⚠️ The batch is capped and ordered OLDEST FIRST, and grandfathering means
    # "created at or before the boundary" — so grandfathered accounts are
    # exactly the rows the batch reaches first. They also never gain a satisfied
    # stamp (the exemption is re-evaluated per request, never written down), so
    # they match the cheap pre-filter forever.
    #
    # Left in the query they are permanent residents: on any install with more
    # than a batch of pre-existing users — an established site that has just
    # switched invite-only on, i.e. the install the janitor exists for — they
    # fill every batch, `access_satisfied?/1` rejects all of them, and the sweep
    # deactivates nobody, every day, forever. The per-account check keeps the
    # result CORRECT while the feature is silently inert.
    test "a grandfathered account never occupies a batch slot" do
      before_boundary = register_user()
      after_boundary = register_user()

      # Both are well outside any retention window; only which side of the
      # boundary they fall on is under test.
      backdate(before_boundary, days_ago(20))
      backdate(after_boundary, days_ago(10))

      :ok = enable_invite_only(days_ago(15))

      uuids = Enum.map(Referrals.prune_candidates(5), & &1.uuid)

      refute before_boundary.uuid in uuids
      assert after_boundary.uuid in uuids
    end

    test "with grandfathering off, the older account is a candidate again" do
      # The complement, and the reason the exclusion has to read the setting
      # rather than always apply: turning grandfathering off is precisely how an
      # operator asks for these accounts to be swept.
      before_boundary = register_user()
      backdate(before_boundary, days_ago(20))

      :ok = enable_invite_only(days_ago(15))
      Settings.update_setting("referral_grandfather_existing", "false")

      assert before_boundary.uuid in Enum.map(Referrals.prune_candidates(5), & &1.uuid)
    end
  end

  defp days_ago(days) do
    DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)
  end

  # `inserted_at` is set by the insert, so the only way to have an account that
  # is genuinely old is to move it.
  defp backdate(user, %DateTime{} = at) do
    {1, _} =
      Repo.update_all(
        from(u in PhoenixKit.Users.Auth.User, where: u.uuid == ^user.uuid),
        set: [inserted_at: at]
      )

    :ok
  end

  describe "pre-0.6 code redemption (lazy backfill)" do
    setup do
      on_exit(fn -> ModuleRegistry.unregister(ReferralsWithHistoricalUse) end)
      :ok
    end

    test "a usage row satisfies the gate and stamps the account" do
      # The 0.4 flows recorded usage but never wrote the satisfied-stamp; the
      # 0.6 gate trusted only the stamp, parking exactly the users who did
      # what invite-only asked of them. Found on a live install the day of
      # its 2.5.0 upgrade.
      user = register_user()
      enable_invite_only(long_ago())
      ModuleRegistry.unregister(EnabledReferrals)
      ModuleRegistry.register(ReferralsWithHistoricalUse)

      refute Referrals.marked_satisfied?(user)

      assert Referrals.access_satisfied?(user)

      # And the answer was stamped, so the usage query never runs again.
      assert Referrals.marked_satisfied?(Auth.get_user(user.uuid))
    end

    test "no usage row, no admission" do
      # EnabledReferrals exports no signup_use_exists?/1 — the dispatch
      # returns :error, which the gate reads as "cannot confirm, do not
      # admit", same rule as every other predicate here.
      user = register_user()
      enable_invite_only(long_ago())

      refute Referrals.access_satisfied?(user)
      refute Referrals.marked_satisfied?(Auth.get_user(user.uuid))
    end
  end
end
