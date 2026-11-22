# PR #1053 — Browser and phone push notifications

Reviewed `dbd999d30` against `7c1d81e07`. The merge includes the following fixes.

| Severity | Finding and resolution |
| --- | --- |
| BUG - HIGH | Removing one account’s device revoked the provider subscription for every account sharing the browser. Removal now deletes only that account’s binding. The LiveView regression checks the other account’s binding and the absence of a browser unsubscribe event. |
| BUG - HIGH | Two nodes could generate different VAPID keys on first use. Encryption-key rotation also skipped the private key inside the JSON setting. Initialization now reads the winning key under a PostgreSQL advisory lock and stores it through the restricted scalar setting changeset. A database test rotates the encryption key and verifies the original signing identity still loads. |
| BUG - MEDIUM | A locale segment in the service worker, install, manifest, resubscribe or click URL could send a non-default-language browser to an unregistered route. These controller URLs now use the configured mount prefix and omit the locale segment. The hook also waits for its own worker to activate before subscribing. |
| BUG - MEDIUM | Subscription rotation could overwrite a newer rotation or raise when the replacement endpoint already belonged to another installation. The update now matches the old keys and endpoint hash, handles uniqueness conflicts and leaves both subscriptions intact. A late provider response also checks both keys before updating or deleting a device. |
| BUG - MEDIUM | A scheduling failure could leave a pending notice behind and count it again on retry. The notice and grouping job now commit together when Oban uses the application repo. Device delivery also rechecks the site switch before contacting the provider. |
| BUG - MEDIUM | The profile card referred to a Browser column on a separate, permission-gated page. People can now edit their own per-type choices on the card. Initial email-derived preferences and the binding commit together, preserving existing push choices. |
| BUG - MEDIUM | The settings form reported success even when one of its three writes failed. The writes now share a transaction and the form reports its outcome. The restricted VAPID setting also satisfies the repository’s empty-default invariant. |

## Verification

PostgreSQL integration coverage includes V235 and the named-schema migration chain, shared devices, rotation conflicts, site disablement, account switching and encryption-key rotation. A Chromium smoke test mounted the shipped hook outside the service worker scope, activated the worker, and injected a push event. Chromium displayed the expected notification text and click URL. External provider delivery and physical iOS devices were outside this smoke test.

The final `mix precommit` gate passed, including 938 JavaScript tests. The full `mix test --max-cases 8` run on PostgreSQL reported 99 doctests, 16,295 tests, zero failures and 34 skipped (one excluded). The database role lacks `CREATEROLE`.
