# PR #1017 — Add a long poll, message reactions and opt-in module sub-permissions for a site bot reader

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; two nitpicks fixed

Groundwork for a feature module that reads the site bot all the time: `getUpdates` waits for the request's own
`timeout` plus ten seconds, `Telegram.set_message_reaction/5` wraps `setMessageReaction`, and a module can declare a
sub-permission with `opt_in: true`, which keeps it from the Admin role unless an Owner grants it.

The conflict with #1013 in `telegram.ex` was resolved before the merge, in `c87283a9c`: both sides added functions after
`send_message_with_token/4`, and all of them stay.

## Checked and sound

- **An opt-in key cannot reach Admin through a registry that is not up yet.** This was the first worry, because
  `opt_in_admin_key?/1` answers false when the registry is empty and that fails open. It is not reachable.
  `ModuleRegistry` starts before `Dashboard.Registry` and `AdminGrants` (`supervisor.ex`), and an empty registry also
  gives `sub_permission_keys/0` nothing to grant, so the key and the knowledge that it is opt-in arrive together.
- **The tab registry cannot grant one either.** `auto_register_custom_permission/1` only grants keys in `builtin_keys`,
  which holds no sub-keys, and `register_custom_key/2` rejects dotted keys.
- **The sweep is the only path that skips the check.** `grant_to_admin_once/2` (the `AdminGrants` retry) and
  `auto_grant_to_admin_roles/1` both go through `grant_to_admin/2`.
- **The Admin fallback in `Scope` is not a way round.** It hands out `all_module_keys/0` only while the permissions
  table is missing, before V53, the same as for core's opt-in keys.
- **`holds_all_enabled_permissions?/1` stays true for a default Admin.** `admin_baseline_exclusions/0` reads the opt-in
  keys at call time. That walks the registry a second time per call, on top of the walk `enabled_module_keys/0` already
  makes. The referral gate can reach it on a page load, after its cheaper checks, so the cost is real but only doubles
  one that was already paid there. Not measured.
- **`reaction: []` reaches Telegram.** The body is built without `maybe_put/3`, so clearing is not dropped as an empty
  value. Telegram itself is stubbed in the tests: none of this ran against a real bot.
- **`receive_timeout/1`:** `max(15 s, timeout + 10 s)` keeps the old wait for `timeout: 0` (the linking poll) and for
  anything below 5 s, as the PR says.

## Findings

### NITPICK — the "authoritative chokepoint" comments stopped being true (fixed)

Two comments said `auto_grant_to_admin_roles/1` is the one place opt-in keys are stopped, whichever path asks. This PR's
sweep filters its own keys and then calls `grant_to_admin_now/2`, which checks nothing, so a reader relying on the
comment would be wrong about the one path that matters most. Both now say where each path is stopped.

### NITPICK — the sweep read the opt-in set before the keys (fixed)

`sweep_admin_grants/1` read `opt_in_admin_keys/0` first and the key list second. A module registered between the two
reads would have its opt-in key in the list and not in the filter, and nothing checks a key past that filter: a small
window, but on the side that hands a deliberate permission out. The set is now read after the list. No test: the
window cannot be hit deterministically.

### NITPICK — no CHANGELOG entry (left, for the release)

The PR adds none, and the entry belongs to the release commit.

## Tests added

None for this PR: the reordering has no deterministic reproduction and the rest was comments. The PR's own tests cover
the behaviour, and they ran again on the merged tree.

## Validation

See the commit for the gate.
