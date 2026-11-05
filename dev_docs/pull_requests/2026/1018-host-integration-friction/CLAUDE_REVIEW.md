# PR #1018 — Ease the host-integration points one host had to work around

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve with fixes; one improvement and two nitpicks fixed, one
improvement left

Docs and installer work from a production host's list of workarounds: `update_user_custom_fields/3` says it replaces
the whole map, a new "Your App as a Module" guide, the daisyUI check reads the git dependency a newer `phx.new` declares,
a fresh Oban block picks the PG notifier behind a pooler, and the installer imports `PhoenixKit.Test.Fixtures` into the
host's `ConnCase`.

## Checked and sound

- **The daisyUI change rests on something real.** Checked against the upstream repositories, not the PR text: `phx.new`'s
  template declares `{:daisyui, github: "saadeghi/daisyui", ...}` and loads `daisyui/packages/bundle/daisyui`, pinned to
  `v5.5.20`. `packages/bundle/daisyui.js` exists at that tag and at the latest (`v5.7.50`), and carries exactly one
  `version = "…"` marker, so `installed_version/1` reads the right number.
- **The guide's claims hold.** `before_user_delete/1` runs for every discovered module, enabled or not, and a raise is
  logged and does not stop the deletion. Discovery reads the code path and each `.app`'s `applications`, so a host's own
  app qualifies. `oban_crons/0` reaches the crontab through a `.beam` scan, which is what the install and update tasks
  need. The five required callbacks are the five named, and `merge_user_custom_fields/3` and
  `delete_user_custom_field/3` both write at the database level.
- **`@fixture_names` matched** all eight public functions of `PhoenixKit.Test.Fixtures`, and the module ships in `lib/`.
- **An `import` inside `quote` warns nobody.** A test file that uses no fixture gets no unused-import warning: tried in
  a script, a plain unused `import` warns and the same import from a `__using__` macro does not.
- **`Oban.Notifiers.PG` exists** in the pinned Oban, and the `Elixir.Application` spelling is needed: `Application` is
  aliased to Igniter's in that module.

## Findings

### IMPROVEMENT - MEDIUM — the installer edited the host's ConnCase on `--dry-run` (fixed)

`ensure_conn_case_import/1` ran inside the Igniter pipeline but called `File.write!/2`, so the file changed at once: on
`mix phoenix_kit.install --dry-run`, and when the person answered no to the diff, which never showed the edit at all.
It also read from disk, the stale read `BootHook` documents as a bug.

It now goes through the buffer, as `BootHook` does (`Igniter.exists?/2`, `Igniter.update_file/3`), so the edit is in the
diff and a dry run leaves the file alone. The other test sources are still read from disk, which is harmless and does
not parse them, and are passed as an argument so a test project can supply its own. `JsIntegration` has the same
`File.write!/2` pattern on the host's layout and `app.js`. That predates this PR and is not changed here.

### NITPICK — the doctor spelled the product "Daisyui" (fixed)

`String.capitalize/1` lowercases everything after the first letter, so `mix phoenix_kit.doctor` printed `Vendored
daisyui is 5.0.0` and `Daisyui dependency (deps/daisyui) is 5.0.0`. The messages now start `Your …`, as the installer's
own warning does. `daisyui_outdated_message/4` is exposed `@doc false`, like the task's other pure decisions, so a test
can hold it.

### NITPICK — a macro or a delegate with a fixture name went past the clash check (fixed)

The check matched `def` and `defp` only, but `defmacro`, `defmacrop` and `defdelegate` clash with the import the same
way, and the cost of a miss is a compile error at every call site of the host's tests. The fixture list and the module
are also two lists that must agree, so a test now walks `PhoenixKit.Test.Fixtures.__info__(:functions)`.

Comments and the moduledoc that still spoke only of a vendored file were brought up to date, in `AGENTS.md` too.

### IMPROVEMENT - MEDIUM — any non-5432 port writes the PG notifier into config.exs (left)

`classify_config/1` was written for the doctor, where a wrong guess costs a line of advice. Here it decides a runtime
setting: the install task reads the dev config, and a local Postgres on `5433` (or Supabase's `54322`) writes
`notifier: Oban.Notifiers.PG` into `config/config.exs`, for every environment. A deployment with several nodes that are
not clustered then loses cross-node signals it would have had.

Left because the effect is small and visible: jobs still run, the stager falls back to `:local` when the notifier is not
clustered, and the generated comment says what was done and why. Requiring a pooler's name or `6432` would be the fix, if a host ever trips on it.

### NITPICK — a conflict notice repeats on every update (left)

A host whose tests define a fixture name (any `phx.gen.auth` host) sees the notice on each `mix phoenix_kit.update`.
Remembering the answer would need state for a one-paragraph notice.

### NITPICK — no CHANGELOG entry (left, for the release)

## Tests added

- `test/phoenix_kit/install/test_fixtures_integration_test.exs`: the import is staged in Igniter's buffer (a test project
  has nothing on disk, so a direct write sees no file), a second run changes nothing, an earlier step's staged content
  survives, a clash leaves the file alone with a notice, no `ConnCase` is no change, every function of the fixtures
  module counts as a clash, and macros and delegates clash.
- `test/mix/tasks/phoenix_kit_doctor_test.exs`: the product's name keeps its casing for both copies and severities, and
  the message names the copy the host has.

The two doctor tests and the macro test failed before the fixes, on the literal `Vendored daisyui is 5.0.0`. The buffer
tests failed only because the two-argument function did not exist yet, so that failure proves nothing about the old
behaviour; the `File.write!/2` is plain in the old code.

## Validation

See the commit for the gate.
