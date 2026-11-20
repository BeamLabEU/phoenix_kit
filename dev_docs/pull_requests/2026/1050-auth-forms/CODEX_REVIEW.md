# PR #1050 — Auth forms and email confirmation

Reviewed head `6a003b53c` against `8bac7ae14`.

- **BUG - HIGH.** Opening the emailed link in a JavaScript-capable browser consumed the confirmation token on socket connection. This made a preview or automated browser visit sufficient to confirm an account. Restored explicit form submission for account confirmation and email changes. The integration test checks that connecting leaves the account unconfirmed and that submitting redirects and broadcasts a scope refresh.
- **BUG - MEDIUM.** The sign-in and sign-up pages offered a provider whenever its settings switches were on, even when it lacked credentials. Both pages now use the existing configured-provider lookup and keep the result in a LiveView assign so typing in the form does not repeat the lookup. A database-backed test enables two providers and checks that both pages offer only the one with credentials.

Validation passed with `mix precommit`, 252 focused tests against a fresh PostgreSQL database, and the full component directory (1,599 tests and 14 doctests).
