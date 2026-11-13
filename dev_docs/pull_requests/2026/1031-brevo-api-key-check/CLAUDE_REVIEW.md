# PR #1031 — Brevo API check: tell an SMTP key from a bad API key, show Brevo's message, run under Probe

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one follow-up applied

Merged into `main` as 50dba8f18 (fixes #1030). It merged cleanly.

`Validators.brevo_api/2` now refuses an `xsmtpsib-` key before making any request, naming the right key. It runs
`GET /v3/account` under `Probe.run` with `retry: false`, `redirect: false` and `decode_body: false`, the same way
`serpapi/2` does. The verdict comes from a pure `interpret_brevo/2`, which keeps Brevo's `message`, cut to 200
characters. It also tells a 401 caused by Authorised IPs apart from a wrong key.

Checked and fine:
- **Redirects.** The key travels in a custom `api-key` header, and `redirect: false` keeps it from following a
  `Location` somewhere else.
- **Logging.** A transport error goes through `request_failure/2`, so only the tag of the reason is logged. The old
  `inspect(reason)` could carry response bytes.
- **Brevo's message in the UI.** The message is shown only to the admin running the check, and HEEx escapes it. The
  IP-refusal text names the server's own outbound IP, which that admin needs to allow it.
- **Gettext.** The PR's `.po` files carry the five new msgids in all nine locales, with no fuzzy or untranslated
  entries.

## Findings

### IMPROVEMENT - MEDIUM — A key that is not a string was still sent to Brevo (fixed)

`blank?/1` is false for a non-string, and the `xsmtpsib-` check guarded on `is_binary/1`, so an integer or map key
fell through to `Probe.run`. There Req fails on the header value, and `Probe` logs the crash with
`inspect(reason)`. That puts the value in the log and shows the operator "Could not reach the service". The PR's
test asserted only `{:error, _}`, and since `Probe` turns the test plug's `flunk` into that same error, the test
passed while a request was still being attempted.

Fix: a `not is_binary(api_key)` clause answers "Invalid credentials" before any request. The test now asserts that
exact verdict for an integer, a map and a list. Only the no-request branch can produce it, so the test fails if a
request is attempted.

### NITPICK — POT line references drifted (fixed)

`mix gettext.extract --check-up-to-date` failed after the two merges and the direct commits before them. Only `#:`
reference lines differed. Re-ran `gettext.extract` + `gettext.merge`, and no msgid or msgstr changed.

### NITPICK — Brevo's IP message is cut at 200 characters (not changed)

The IP-refusal text Brevo sends runs past 200 characters, so the cut drops the end of its link. Our own text already
says where to go (Security → Authorised IPs), so the loss is cosmetic. The cap is kept.
