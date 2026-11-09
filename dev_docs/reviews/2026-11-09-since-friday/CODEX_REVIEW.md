# PhoenixKit changes since Friday — Codex review

Review date: 2026-11-09.

Scope: core repository changes from the start of Friday, 2026-11-06 UTC,
through `5a651914e`. Base: `6d3d7050e177bd8c73df113d38ee5c428c2c680f`.
The range contains 42 first-parent commits and changes 264 files. This review
does not include independent changes in sibling repositories.

## Review coverage

Reviewed the accumulated changes and their callers, with the greatest depth
on organization authority, typed links, role narrowing and account switching.
Also examined V229, invitation acceptance, user forms/details/lists, avatar
editing and rendering, pagination preferences and URL state, authentication
and mail locales, notification routing, Telegram calls/downloads/linking,
S3 configuration, short-video metadata and capture-date parsing. Checked
translation interpolation and ran the project gate and PostgreSQL-backed tests.

The new features remain in place, including support sign-in's full organization
experience and Admin-to-Admin support sign-in. Fixes below preserve those product
choices. No version bump, release, schema change or migration-manifest edit is
part of this review.

## Findings fixed

### 1. BUG - HIGH — Removing a link bypassed role authority

`OrganizationManagers.update/4` checks who may change their own link and which
roles the actor may give or take away. `remove/4` skipped both checks. A narrowed
manager could remove a person's Supplier or all-role link even when an edit
removing the same access would be refused. A manager could also remove their own
link if another manager remained, contrary to the link contract.

Removal now applies the same own-link and role-rank checks. Host calls retain
their documented authority, and last-manager protection and the administrator's
explicit managerless override remain in place.

Regression coverage: `organization_links_test.exs` exercises prohibited Supplier
and all-role removal, allowed removal within the actor's authority, and self
removal with another manager remaining.

### 2. BUG - HIGH — Legacy organization ties ignored the actor

`PersonOrganizations.attach/4` and `detach/4` delegated older
`users.organization_uuid` ties to Auth setters that authorize nothing. They
accepted a nil actor or an Admin actor whose role had since been revoked, while
their managed-link branches re-authorized the live session.

Legacy writes now use a transaction, the established person/organization/user
lock order and `Actor.admin/1`. They reload the person before changing the tie;
a stale detach cannot clear a newer organization assignment.

Regression coverage: `person_organizations_test.exs` calls the context directly
with no actor and with a revoked Admin session, and verifies the tie is retained.

### 3. BUG - HIGH — Support activity could name the wrong operator

An Admin added with their own credentials can initiate support sign-in. However,
its success event and `impersonated_by/1` named the stack's first account, which
could be an unrelated ordinary account. Switching to a borrowed account also
lost the secondary Admin as the account that authorized that impersonation.
Organization link changes omitted support attribution even when entry into the
organization recorded it.

Each new impersonation now retains its authorizing own session and operator UUID
in the signed browser session. Attribution survives account switches and removal
of the operator's secondary sign-in; further impersonation still requires a live
authorizing session. Older sessions keep the root-account fallback. Removed
borrowed tokens have their provenance pruned. Organization actors carry this
attribution into link lifecycle activity. Header widgets cannot override the new
session key or the organization-slot key.

Regression coverage: `multi_session_test.exs` and
`organization_switching_test.exs` check the initiating event, subsequent scope
attribution, switches, operator-session removal, and context-owned link activity.

### 4. BUG - MEDIUM — Role descriptions stayed stale without language tabs

The edit changeset synchronized a plain label into translated data, but not a
plain description. A role with an existing primary-language description kept
showing that older value after a successful description edit. The form's hydrate
step could also prefer a stale column over the translated primary value.

Both text fields now synchronize when supplied without a translated data map;
hydration reads the primary description. Other language entries remain intact,
and a blank description can be cleared.

Regression coverage: `role_translations_test.exs` verifies editing, clearing,
hydration and preservation of the German translation.

### 5. BUG - MEDIUM — Link-change notifications could not be muted

The new `organization.manager_changed` emitter sets a target user, but the action
was missing from the account notification type. Unknown actions fail open, so
muting account notifications did not mute these changes. Its text fell back to
the machine action name, and it had no settings link.

The action now belongs to the account type and has dedicated copy and the
locale-aware settings link. Added its message to the template and all ten
shipped language catalogues.

Regression coverage: notification prefs and rendering tests verify the mute,
organization-specific copy, German translation and destination.

### 6. BUG - MEDIUM — Widgets still treated added own accounts as borrowed

`MultiSession.impersonated?/1` learned the distinction between own and borrowed
accounts, but `HeaderWidget.impersonating?/1` still classified every non-root
account as borrowed. Widgets such as the Agent panel could therefore disappear
for accounts added with their own password or OAuth credentials.

Account render data now carries `own?`, and the widget hint follows it. Legacy
render data stays conservative. Organization/support provenance also suppresses
a borrowed session's widget when the account-switcher list is absent.

Regression coverage: header-widget unit tests and a real secondary-Admin session
cover own, borrowed, organization and switcher-disabled representations.

### 7. BUG - MEDIUM — A read-only People panel could crash on stale events

After management was revoked, the panel loaded `details: nil`. A subsequent
`open_add` or `open_edit` event dereferenced those missing details and crashed
the LiveView, even though the write contexts correctly refused the change.

The read-only panel now ignores its interaction events. The lost-management
integration test submits both stale dialog events after the panel changes state.

### 8. BUG - MEDIUM — A saved language could break a host return URL

After the post-auth resolver selected a valid destination, `in_saved_language`
blindly rewrote it into the saved language and kit prefix. A host-only route
such as `/__test/crawlers-no-index-probe?from=login` became
`/phoenix_kit/de/__test/crawlers-no-index-probe?from=login`, which the host does
not serve. This affected explicit return destinations as well as configured
host start pages.

The translated candidate is now used only when the current router serves it;
otherwise the selected host path and query are retained. Existing supported
localized destinations continue to use the saved language.

Regression coverage: added a sign-in test using the existing unlocalized host
probe. It failed with the synthesized URL before the fix.

## Validation cleanup

- **IMPROVEMENT - MEDIUM:** test configuration inherited bcrypt's production
  cost of 12 for thousands of fixture hashes. Set `log_rounds: 4` in
  `config/test.exs`, following the installed bcrypt package's test guidance.
  Hashing and password verification still execute; production configuration
  retains its existing cost. The final full suite runs with this test setting.
- The broad suite exposed an existing ImageMagick 7 test-reader issue:
  an opaque PNG without an alpha channel returned zero for the test's `.a`
  expression. Inspection confirmed the PNG was opaque. The pixel reader now
  enables the alpha channel before measuring, preserving actual transparency.
  The existing animation/composite tests verify the result; image-processing
  production code was unchanged.
- Removed an unused default argument from the reconciler test's retry helper,
  eliminating its test-compilation warning.
- Fixed global permission-key leakage from `CustomPermissionKeysConfigTest`.
  It restored application configuration but left its registered `cfg_key_*`
  keys in persistent state. Running it before `ModuleOptInSubPermissionTest`
  reproduced a default-Admin assertion failure: the later test required the
  leaked keys even though the earlier unit test had no database owner to grant
  them. The configuration tests now clear their registry state at setup and
  teardown. The Admin assertion also reports missing keys for future diagnosis.

## Validation results

- `mix precommit`: passed after the final changes. Compilation with warnings
  treated as errors, unused-lock check, test-file compilation, format check,
  strict Credo, Dialyzer with the repository's existing ignores, and **709 JS
  tests** all passed.
- Full PostgreSQL run, seed `473075`, `PGPOOL=12`, `--max-cases 8`:
  **91 doctests, 14,672 tests, 1 failure, 34 skipped, 1 excluded**, in 616.7s.
  Its sole failure was the leaked custom keys described above; the running VM
  had already loaded the old test cleanup. No other case failed.
- The two-file permission reproduction failed before cleanup with the exact
  leaked `cfg_key_*` keys, then passed with the fix: **18 tests, 0 failures**
  using the same seed. `mix test --failed` on the full-suite database then
  passed: **1 test, 0 failures**.
- Focused organization/session/role/notification/widget/composite regression
  run: **255 tests, 0 failures**. Follow-up auth, widget and reconciler checks:
  **57 tests, 0 failures**, including the host redirect regression.
- Integration tests used disposable PostgreSQL databases and the actual
  migration chain. The database role lacks `CREATEROLE`, so the suite excluded
  its `requires_createrole` case. The reported 34 skips remain explicit.
- Checked changed translation catalogues for interpolation consistency and
  ran `git diff --check` successfully.
