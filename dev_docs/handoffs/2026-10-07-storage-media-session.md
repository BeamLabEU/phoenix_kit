# Handoff: PhoenixKit storage and media work (session of 2026-10-07)

Written so a fresh session can continue without the chat. Facts here were true when it was written;
re-check commit hashes with `git log` before relying on them.

## Repos and state (all committed and pushed, working trees clean)

| Repo | Path | Branch | Latest commit |
|---|---|---|---|
| phoenix_kit (core) | `/www/phoenix_kit` | main | `9ec0833bf` |
| phoenix_kit_photos (module) | `/www/phoenix_kit_photos` | main | `4856027` |
| fotki (host app) | `/www/app` | main | `f3bc5a2` |

The host depends on core and the module by **path** (`../phoenix_kit`, `../phoenix_kit_photos`). That
is fine in dev but not deployable. The Fotki `mix.exs` override must go before a real deploy.

## What was done

**Storage / libraries / renditions** (all in core)
- Libraries have detail pages and a storage profile and rendition profile that are locked after
  creation. Dimensions became "Renditions" (tabs: profiles, Health), with deep zoom at library level.
- Video renditions honour their configured size and quality. This needs `ffmpeg`, which is **not
  installed in the container**.
- Subject-aware square thumbnails:
  - `crop_mode` is `center` or `focus`, and the focal point is detected with libvips through `vix`.
  - Migrations V210 and V211.
  - `Storage.FocalPoint` is the detector. There is no per-photo manual control yet.
- Panorama renditions: `fit_by` is width or height.
- The External libraries tab detects libvips, with a why/how description.

**HEIC** (core, pushed)
- A rendition that keeps the original format becomes JPEG (or the alpha format) for HEIC, HEIF and
  AVIF originals, because ImageMagick can read but not write HEIC.
- When libvips cannot decode a photo (the bundled build has no HEVC decoder), `FocalPoint` falls back
  to an ImageMagick-made 512 px preview, `ImageProcessor.preview_jpeg/3`.
- A new "HEIC support (libheif)" row on the External libraries tab. The banner mentions it only once
  a HEIC or HEIF file exists.
- Verified on the real `IMG_5059.heic`: the focal point matches its JPEG export
  (x 0.28125, y 0.125).
- Existing HEIC files are fixed by pressing **Check every file** on their rendition profile.

**Media viewer**
- Core's neighbour warming is gentler:
  - It waits until the current picture has settled, runs at low fetch priority, and skips data-saver
    and 2G/3G connections.
  - It warms small for both neighbours but `large` only for the side being stepped towards.
  - It never warms originals.
- Core announces `pk:viewer-neighbours`. The module's `assets/js/viewer_warm.js` decides about
  originals, using the picture's displayed size (aspect fitted in the viewer box times pixel ratio),
  one neighbour, and low priority.
- The modal carries one JSON attribute, `data-neighbors`.
- **Rule from the user:** the core viewer stays simple, and high-end viewing policy belongs in
  `phoenix_kit_photos`.

**Host fixes in fotki**
- The CSP now allows `https://cdn.jsdelivr.net` for scripts and `blob:` for images. Before that the
  browser blocked Fresco, Tessera and Etcher, so the viewer was half-broken.
- `assets/css/app.css` also scans `../../../phoenix_kit/lib`. `deps/phoenix_kit` is a stale Hex copy
  (2.54.2), so new core classes (like the pill's `left-3`) were never generated. Drop that line when
  going back to the Hex release.

**Plans** (all committed)
- Core `dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md`: self-host the viewer libraries and
  add a visible load-failure notice. Includes two Codex reviews and the revised decisions.
- Core `dev_docs/plans/2026-10-07-etcher-local-sortable-request.md`: the upstream request for
  `window.Etcher.sortableUrl` and `loadSortableFromCdn`. The link was sent to Alex (alexdont, who owns
  Fresco, Tessera, Etcher and Leaf).
- Fotki `dev_docs/plans/2026-10-07-photosync-webdav-endpoint.md`: a WebDAV endpoint so PhotoSync can
  back up phones, with the Codex review folded in.

## Not done / open

1. **Retest on the MacBook:** open a photo from Media with the Network tab cleared. Expect the photo's
   `large`, two small neighbours, and the next photo's `large`, with an original only when the picture
   really needs it. Also upload a `.HEIC` and check the square crop. The final result has not been
   seen in a real browser.
2. **Part A of the self-hosting plan** (shared `loadLibrary`, Fresco-before-layers ordering fix,
   failure notice for Owner/Admin/superadmin, doctor check) is not started. It does not depend on Alex.
3. **Etcher upstream option:** waiting on Alex. Until then the plan uses a temporary workaround.
4. **PhotoSync / WebDAV:** parked. Phase 0 (a logging stub plus a real phone) comes first, and a core
   PR for bounded-memory ingestion is a prerequisite.
5. **Live Photos:** the browser picker only sends the still. A decision is pending on whether motion
   matters (it needs ffmpeg and the PhotoSync route).
6. The user's **iPad not uploading JPEGs** was never investigated.
7. **Fotki housekeeping:** the CSP jsdelivr entry can come out after self-hosting ships, and so can the
   Tailwind line when going back to Hex.

## How to work here

- **Host app:** `supervisorctl restart elixir` (logs at `/var/log/elixir.log`). Core `.ex`, `.heex` and
  `.po` edits hot-reload. Run `cd /www/app && MIX_ENV=dev mix compile` to re-vendor `phoenix_kit.js` and
  `phoenix_kit_modules.js` after editing either bundle.
- **After a pull in core:** run `mix deps.get`. A lock mismatch on `phoenix_kit_templates` bit us once.
- **Core tests:** start Postgres with `pg_ctlcluster 18 main start`, then
  `MIX_ENV=test mix test --max-cases 8`. Run it with `run_in_background` on the command itself (a
  nested `&` gets killed). The full suite takes about 9 to 10 minutes (8,805 tests passed before the
  viewer changes). JS tests: `node --test test/js/*.test.cjs` (308 passing). Module JS tests:
  `node --test assets/test/*.test.js` in the photos repo (24 passing).
- **Before committing core:** `mix format`, `mix credo --strict`, and
  `mix compile --warnings-as-errors`. After a migration edit, restamp the chain hash via
  `Mix.Tasks.PhoenixKit.ReleaseCheck.compute_chain_hash/0`.
- **Translations:** run `mix gettext.extract --merge`, then fix each locale's fuzzy entries by hand.
  For merge conflicts in `.po` files, merge entry by entry against the common base.
- **Photos module quirks:**
  - Git needs `-c safe.directory=/www/phoenix_kit_photos` (the repo ownership differs).
  - `mix assets.build` or a host compile can modify its `mix.lock`. Revert that with
    `git checkout -- mix.lock`, because it is not part of the work.
- **Browser testing from the container:** Playwright and Chromium are installed (`/opt/pw`). The
  permission system blocked creating a throwaway Owner account, so the UI could not be driven. Provide
  a test login if you want that.
- **Commit rules:** commit and push only when the user says so. Messages start with Add, Update, Fix,
  Remove or Merge. End them with the Co-Authored-By trailer.
