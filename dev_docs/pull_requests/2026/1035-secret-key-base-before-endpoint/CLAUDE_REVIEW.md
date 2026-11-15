# PR #1035 — Fix integration credentials unreadable before the endpoint starts

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; no changes

Merged into `main` as 62f61a3ce (branch `skb-explicit-config`).

The legacy key tier (derived from `secret_key_base`) used to read the secret only from `Endpoint.config/1`, which
raises until the endpoint's ETS table exists. Code that ran before the endpoint started (the settings cache warmer, an
Oban job at boot), or on a node that never starts it, resolved no key. It then treated every `enc:v1:` credential as
missing. The lookup is now: `config :phoenix_kit, :secret_key_base` → the running endpoint → the endpoint's app env
(`Application.get_application(endpoint)` + `get_env(app, endpoint)`). The app env is skipped when the endpoint defines
the deprecated `init/2`. A no-key decrypt now logs the fix once per VM, and the `decrypt_fields/1` error names it too.

Checked against Phoenix:
- **Same secret before and after start.** `Phoenix.Endpoint.Supervisor.init/1` builds the running config as
  `merge(defaults ++ child-spec opts, app env)` (`Phoenix.Config.from_env/3`). The app env therefore wins over
  child-spec opts, so a secret read from the app env before start is the one the endpoint runs with. The one exception
  is `init/2`, which can replace it, and the PR skips the app env in that case. The `Code.ensure_loaded?` guard
  matches Phoenix's own check there (`function_exported?/3` is false for a module not loaded yet).
- **No empty-secret key.** `usable_secret/1` turns `""` into `nil` on both reads, so no key is ever derived from an
  empty string.
- **Hot path.** The app-env read, which walks the loaded apps' module lists, runs only when the running endpoint gives
  nothing, which means before start.

## Findings

### NITPICK — The app-env read can miss the endpoint's `otp_app` (not changed)

`Application.get_application/1` names the app whose `.app` file lists the endpoint module. That is the endpoint's
`otp_app` in every generated layout, umbrella included (`otp_app: :my_app_web`). An endpoint written as
`use Phoenix.Endpoint, otp_app: :other_app` would be looked up under the wrong app and find nothing. That fails safe:
no key, exactly the behaviour before this PR. Phoenix does not expose `@otp_app` before start, so there is no better
source. Left as is.

### Note — A worker node with a different secret now writes ciphertext others cannot read

A node that never starts the endpoint used to write plaintext (no key). It now encrypts under whatever
`secret_key_base` its app env carries. If that is a placeholder, web nodes cannot decrypt what it writes. The
integration guide says every node must share the value. The CHANGELOG entry describes the new lookup order, which is
enough for an operator to notice. No change.

## Validation

`test/phoenix_kit/integrations/encryption_test.exs`, `test/phoenix_kit/integrations`, `test/integration/integrations`
on a fresh scratch DB: green.
