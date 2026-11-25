# Browser run under a strict Content-Security-Policy

A throwaway host (`server.exs`) that renders kit components behind the policy of
`guides/content-security-policy.md` Option 1 (plus `style-src-attr 'unsafe-inline'`), and a
Playwright script (`run.cjs`) that opens it in headless Chromium. No database.

```bash
# from the repository root
export PK_SCRATCH=$(mktemp -d)
cp dev_docs/handoffs/2026-11-25-csp-browser-harness/app.js $PK_SCRATCH/
# the bundles from before the fixes, for the control runs
git show 55039edd7:priv/static/assets/phoenix_kit.js       > $PK_SCRATCH/phoenix_kit.old.js
git show 55039edd7:priv/static/assets/phoenix_kit_admin.js > $PK_SCRATCH/phoenix_kit_admin.old.js

MIX_ENV=test mix run --no-start dev_docs/handoffs/2026-11-25-csp-browser-harness/server.exs &
# wait for "harness up on 4177"

PK_PLAYWRIGHT=/path/to/node_modules/playwright-core \
PKCHROME=/path/to/chrome-headless-shell \
PKLIBS=/path/to/extra/shared/libs \
  node dev_docs/handoffs/2026-11-25-csp-browser-harness/run.cjs
```

`?mode=one|two|late` on every page: one nonce for both kinds, a different nonce per kind, or a
nonce assigned after the first reading (a host plug placed after `Plugs.Integration`).

What it does **not** cover: `Plugs.Integration` itself (it needs a database; `H.First` calls the
same `CSP.put_nonces_first/1`), the kit's real router and layouts, the consent widget, the table's
column fitting, the preview card, the language switcher, live navigation between two pages.
