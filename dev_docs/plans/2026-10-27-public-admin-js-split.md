# Plan: public pages load only the public JavaScript; admin code loads on demand

Status: **implemented on this branch** (from `upstream/main`, core 3.0.0), as approved; the sections below are the
design, with what changed on the way marked **(as built)**. The how-to for hosts and contributors is
`guides/public-and-admin-javascript.md`.

## The problem

A host imports `priv/static/assets/phoenix_kit.js` (or loads its vendored copy with a `<script>` tag) and spreads
`window.PhoenixKitHooks` into `LiveSocket`. Every page — a shop front page as much as the email dashboard —
therefore downloads, parses and compiles the code of the whole admin area.

Measured on this tree (esbuild 0.25.4, `gzip -9`):

| What | Raw | gzip | minified | minified + gzip |
|---|---:|---:|---:|---:|
| `phoenix_kit.js` as shipped | 764 466 | 226 325 | 412 810 | 131 912 |
| — Chart.js 4.5.1 (lines 1–20, used by one hook, `EmailCharts`) | 208 689 | 70 498 | 208 153 | 72 582 |
| — the 72 hooks and helpers (lines 21–end, hand-written, never minified) | 555 777 | 155 968 | 203 053 | 58 723 |
| `phoenix_kit_modules.js` built from 19 prebuilt module bundles | 476 593 | 132 699 | 266 755 | 77 275 |

Two facts that shape the design:

1. **A readable file is served as it is.** The `:phoenix_kit_js_sources` compiler copies `phoenix_kit.js` and
   concatenates the module bundles without minifying either. A host that `import`s `phoenix_kit.js` into its
   `app.js` gets it minified by its own production build; a host that loads the vendored `<script>` does not.
2. **The spread copies.** `hooks: {...window.PhoenixKitHooks}` runs once, when `LiveSocket` is built. A hook
   added to the object afterwards is invisible to the host. Whatever is loaded later must already have a
   *name* in `window.PhoenixKitHooks` when the spread runs.

(A host that includes `phoenix_kit.js` both ways — a `<script defer src=vendor/phoenix_kit.js>` *and* an `import`
in `app.js` — downloads it twice; `window.PhoenixKitInitialized` stops the second run but not the second download.
That is host wiring, noted in the open questions; the design below does not depend on it.)

## Decision

### 1. Three artifacts

| Artifact | Contents | Loaded |
|---|---|---|
| `phoenix_kit.js` (same path, same two ways to include it) | the shared library loader, the **public hooks**, and a **stub for every admin hook** under the hook's real name | always, as today |
| `phoenix_kit_admin.js` (new, `priv/static/assets/`) | the real implementations of the admin hooks, assigned to `window.PhoenixKitAdminHooks` | on demand, once per page session |
| `chart.umd.js` 4.5.1, **pristine upstream**, as a vendored library (`vendor_libs/chartjs/`, README + licence + sha256 like Panzoom) | Chart.js only | on demand, by `EmailCharts` on its first mount |

The inlined Chart.js is byte-identical to upstream `chart.umd.js` 4.5.1 except for its trailing
`sourceMappingURL` comment (renamed to a map that does not exist), so replacing it with the checksummed upstream
file loses nothing. `window.Chart` is no longer defined at page load — it appears when `EmailCharts` first
mounts (a host that needs `window.Chart` on its own pages loads its own; the old guard already deferred to one).

### 2. How the admin bundle is delivered — as one more vendored library

`PhoenixKit.Install.ViewerLibraries` already vendors Fresco, Etcher, Leaf, SortableJS, … into
`priv/static/assets/vendor/lib/<name>-<version>-<hash>.js`, writes their names into `window.PHOENIX_KIT_LIBS`
(inside `phoenix_kit_modules.js`), and `phoenix_kit.js` loads them with `loadVendored` — one in-flight promise per
library, a retry, CSP detection, an admin-only failure notice (`LibraryLoadNotice`), a CDN fallback only on opt-in.
The admin bundle becomes `PHOENIX_KIT_LIBS.admin` (and `chartjs`) in that same mechanism. Nothing new to learn,
nothing for the host to change: the compiler that already runs on every `mix compile` writes the file, the hashed
name makes it cacheable for good (`?vsn=d` → Plug.Static immutable header).

### 3. The stub

For each admin hook name `phoenix_kit.js` defines the same shape `lazyHook` already gives Leaf and Fresco:

```js
window.PhoenixKitHooks[name] = adminStub(name);   // mounted() loads the bundle, then becomes the real hook
```

`mounted()` waits for `loadVendored("Admin", "admin")`, copies the real hook's callbacks onto the hook instance
(`updated`, `destroyed`, `beforeUpdate`, `reconnected`, … — `this` is the LiveView `ViewHook`, so
`this.el`, `this.pushEvent`, `this.handleEvent` all work) and calls its `mounted` with that `this`. A hook
destroyed while loading never mounts late. Every stub shares the one in-flight promise, so N admin hooks on a page
cost one request. A failed load leaves the feature absent and reports through the existing library notice.

Because **every name stays in `PhoenixKitHooks`**, nothing a host (or an external module) already references can
become an "unknown hook", and the classification below only decides *performance*, never *correctness*: a hook
sorted into the wrong list costs a lazy request on a page that did not need it, or bytes on a page that did not.

Known limits, accepted and documented: `updated` calls and `push_event`s that reach a stubbed hook in the window
between its mount and the bundle's arrival are not replayed (`real.mounted` reads the DOM as it is then). That
window is only the first admin page of a session, and it is closed in practice by an **early start**: the admin
layout (`LayoutWrapper`) carries a marker attribute and `phoenix_kit.js` starts the download at
`DOMContentLoaded` when it finds it, i.e. before the socket has joined. The marker is an optimisation, not a
requirement.

### 4. What is public and what is admin

Rule: **a hook stays public when core or a known module renders it from a surface that is not the admin area or
the user dashboard, or when it is a global behaviour every page needs; generic small form/UI primitives stay
public (their cost is a few hundred gzip bytes each, less than one lazy request); specialised or heavy hooks go
to the admin bundle.** The split is an explicit list in `phoenix_kit.js` (`ADMIN_HOOKS`), and a node test pins it.

*Public, 31* — LibraryLoadNotice, CookieConsent, FlashAutoDismiss, TimezoneOffset, TimezoneDetector,
LanguageSwitcherSearch, LanguageSwitcherPosition, PkDialog, PkDialogTrigger, PopupLink, ResetSelect,
SelectOnMount, TimeAgo, CopyToClipboard, FadeOut, PreserveScroll, InfiniteScroll, PageSizeAutoFit,
MaintenanceCountdown, PkShiftEnter, PkUrlMirror, PhoenixKitUrlState, PkCheckboxIndeterminate, PkDateInput,
PkChartCrosshair, ViewportPopover, and the five already-lazy library wrappers Leaf, FrescoViewer, FrescoCanvas,
TesseraLayer, EtcherLayer.

*Admin, 42* — SortableGrid, MediaImageZoom, MarkdownEditor, InstantViewer, ViewerKeydown, ViewerPaneFit,
MediaViewerDialog, ViewerSwipe, ViewerGallery, ViewerHiresLoading, AnnotationBurn, EtcherTooltipActions,
AnnotationComposerPosition, EtcherReset, StackMemory, StackExpand, WaveformPlayer, MediaDragDrop,
FolderDropUpload, UploadResume, RemovalModal, UploadStats, UploadGuard, ContextMenu, AvatarCrop, ImageEditor, SearchPicker,
MentionInput, PkDialogDraft, PkHashHighlight, BulkSelectScope, TableLocalSearch, TableFit, TableCardView, RowMenu,
RowMenuAuto, ListFilter, TreePickerSearch, CrumbSwitcher, AdminSidebarScroll, IntegrationPickerSearch,
EmailCharts.

By source span the public hooks are ~107 KB of ~507 KB of hook code (the remainder is helpers shared with, or
private to, the groups above). A final figure comes from the split itself, measured in the tests (a size budget)
and on the host.

The same pass classifies the **non-hook top-level code** (the collapse scroll keeper, the change cue, the global
textarea / stray-click / unsaved-changes listeners, the Etcher tooltip bridges): code that runs for every page
stays public, code that only serves admin hooks moves with them. A helper used from both sides stays public and is
handed to the admin bundle through a private `window.PhoenixKitInternals` object — the admin file is a plain
script and cannot see the public file's closure. Which helpers those are is found mechanically: a TypeScript
`checkJs` pass over each file lists every identifier it uses and does not define (it reports exactly two on today's
file — the `define` of Chart.js' UMD wrapper and the `Chart` global), so a forgotten helper shows up as a named
error, not as a runtime `ReferenceError` in a browser.

### 5. Alternatives considered

| Option | Verdict |
|---|---|
| **Stubs + a lazily loaded bundle** (above) | **Chosen.** Needs nothing from the host; the old inclusion styles keep working; reuses the library machinery. |
| Runtime hooks (LiveView 1.1 `script[data-phx-runtime-hook]`, `window.phx_hook_<Name>()`) | Rejected for core. The hook's code would be inlined into every admin response (no browser cache, hundreds of KB per page), it needs LiveView ≥ 1.1, and the page that carries the script is again the host's layout. It remains the right tool for a small module that wants to ship one hook (the compiler docs already say so). |
| `<script defer src=admin.js>` in the admin layout | Rejected as the mechanism: the spread has already happened (no stubs → "unknown hook"), and a script element inserted by a LiveView patch is not executed, so it would not load on a live navigation from a public page into the admin area. Kept only in spirit as the early-start marker above. |
| Host `import()`s the admin file | Rejected: needs a change in every host's `app.js`. The requirement is `deps.update` + `phoenix_kit.update`. |
| A `Proxy` for `window.PhoenixKitHooks` | Impossible: `{...proxy}` reads the target's own keys at spread time, which is the problem itself. |
| Build step that generates both files from many sources | Rejected for now: the repo has no JS build, `phoenix_kit.js` is edited by hand by several branches, and a 13 000-line move into new directories would conflict with all of them. The split moves hook code **verbatim** (no reformatting) so a rebase is a conflict in one block, not a rewrite. |

### 6. Minification

`phoenix_kit_modules.js` is built by the compiler from other packages' prebuilt files; `phoenix_kit.js` and the new
admin file are hand-written. All three go through the minifier `ViewerLibraries` already has: the **host's own
esbuild** (the binary its `mix assets.deploy` installed), run as a plain transform — no bundling — when
`minify?()` is true (production, or `config :phoenix_kit, minify_libraries: true`). A host without `:esbuild`, an
esbuild that is not installed yet, or a failed transform gets the readable file and a note — never a broken build,
and the next compile minifies once the binary is there. **(as built)** `config :phoenix_kit, js_minifier: {Mod, :fun}`
names another minifier, and minifying an already minified file is harmless (checked: the node tests pass on
the output of one and of two esbuild passes). The vendored `phoenix_kit.js` and
`phoenix_kit_modules.js` keep their fixed names (the layout references them); `vendor/lib/` files keep hashed names.

Expected (same esbuild, measured above): `phoenix_kit_modules.js` 132 KB → 77 KB gzip for the 19-bundle build; the vendored
`phoenix_kit.js` 226 KB gzip as shipped → 25 KB gzip minified for the public part (**as built**:
220 KB raw / 62 KB gzip readable; the admin bundle is 345 KB / 98 KB readable, 125 KB / 36 KB gzip minified;
Chart.js stays its own 208 KB / 70 KB file that only the email dashboard fetches).

`dev` builds stay readable, so a stack trace points at real lines.

### 7. Module bundles (`js_sources/0`) — optional second phase

Most of `phoenix_kit_modules.js` is admin code (in the 19-bundle build measured above, roughly 300 KB of its
476 KB belongs to admin-area modules). The compiler cannot see hook names inside a bundle, which is exactly what a
stub needs. So the extension is opt-in and declared by the module:

```elixir
%{app: :my_module, file: "static/assets/my_module.js",
  global: "MyModuleHooks", scope: :admin, hooks: ["MyModuleGrid", "…"]}
```

An entry without `scope:` is public, as today (so no module has to change, and an old core ignores the extra keys
of a new module). An `:admin` entry without `hooks:` is a compile error (loud, like the other `js_sources`
validations). The compiler appends admin entries to `phoenix_kit_admin.js` (folded into
`window.PhoenixKitAdminHooks`) and writes stubs for the declared names into `phoenix_kit_modules.js`. No module
repository is changed by this branch; the mechanism, its tests and the `PhoenixKit.Module` docs are. **Decision
for the head: this branch, or a follow-up** (it is independent of sections 1–6).

### 8. Host transition

| Host today | After `mix deps.update phoenix_kit` |
|---|---|
| `:phoenix_kit_js_sources` in `:compilers`, `<script src=vendor/phoenix_kit.js>` + `vendor/phoenix_kit_modules.js` (the installer's layout) | `mix compile` vendors the lean `phoenix_kit.js`, the admin file into `vendor/lib/`, and the facts. Nothing else. |
| the same, plus `import ".../phoenix_kit.js"` in `app.js` and the spread | Works: the imported file is the same lean one; the vendored tag (if both are present) wins as before. |
| `import` only, no compiler, no `vendor/` files | The viewer libraries already need `mix phoenix_kit.update` here; so does the admin bundle. `mix phoenix_kit.update` vendors everything and inserts the facts tag. `mix phoenix_kit.doctor` gets a check that warns when the facts name no `admin` file or the file is not on disk. |

**(as built)** Where the files are served from is resolved in the browser in this order: (1)
`window.PHOENIX_KIT_LIB_BASE` — the host's own word, or `config :phoenix_kit, library_base_url: "…"` (read at
compile time), which the facts turn into that variable without overriding one the host set; (2) next to the tag
that loads `phoenix_kit.js`, when that is the vendored bundle (`phoenix_kit.js`, `phoenix_kit-<md5>.js`) — a host
behind a CDN (`static_url`) or under a path prefix needs no configuration; (3) the compiler's default
`/assets/vendor/lib/`, written to the facts as `PHOENIX_KIT_LIB_BASE_DEFAULT`, for when no such tag exists (the
file bundled into `app.js`); (4) the directory of the running script, for facts from an older version. Nothing
depends on where the facts file is served from, so a host that moves, defers or re-minifies it is unaffected. A
module's admin stubs are registered whichever of `phoenix_kit.js` and `phoenix_kit_modules.js` runs first.

## Order of work (TDD, one logical commit each)

1. **Chart.js as a vendored library.** Tests: `ViewerLibraries.libraries/0` lists `chartjs` with its checksum;
   `EmailCharts` loads it before drawing and shows its "unavailable" state on failure; the committed file equals
   upstream's sha256. Commit the vendored file + README, remove the inline copy.
2. **The split.** Tests first (node): every pre-split hook name is in `PhoenixKitHooks` after the split (name
   set frozen from the current file); the public file contains no admin implementation and no Chart.js; the admin
   file's keys equal `ADMIN_HOOKS`; stubs load once for N mounts, delegate `mounted/updated/destroyed` with the
   right `this`, survive destroy-while-loading and a failed load; a public-size budget. Then move the code; the
   existing 39 `test/js` files are pointed at the file that now holds what they test.
3. **Delivery.** Tests: `vendor_all` writes the admin file under a content-hash name, the facts name it, an
   unchanged compile writes nothing, `minify?` true + esbuild present yields smaller files for the three outputs,
   absent esbuild yields the readable ones. Facts file sets the library base. Doctor check.
4. **Early start marker** in `LayoutWrapper` / dashboard layout and the `DOMContentLoaded` probe.
5. **Module scope** (section 7), if the head wants it in this branch.
6. **Docs**: this plan → a guide (`dev_docs/guides/`), `AGENTS.md` landmine ("a new hook goes in the public list
   only if…"), the `PhoenixKit.Module` and compiler moduledocs.

Gates before the report: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`,
`mix dialyzer`, the full `mix test` run on the scratch database, `mix test.js`.

## Verification on a host

A development host, **from a scratch copy** (its `mix.exs` is not changed here): size of the JS a public page
downloads, before and after, raw and gzip, from the server's responses and from a production-style
`esbuild --minify` of the same inputs. Only figures about core itself and about an empty host go into the
PR text and the docs. Admin: no browser in this container, so the checks are the node tests of
the stubs, an HTTP check that the admin page's assets (admin file, Chart.js, facts) are served with the right
names and cache headers, and — if the head can run one — a browser pass over the dashboard charts, an editor, a
sortable list and the media browser with the console open.

## Risks

- **Merge conflicts.** The move deletes a large block from `phoenix_kit.js`; any open branch editing a moved
  hook conflicts in that block. Mitigation: verbatim move, one commit, rebase early.
- **Document-level listeners of an admin hook** (the media browser's box select and Shift-click range, #991) are
  installed when the admin bundle runs, no longer when `phoenix_kit.js` loads, and #991's fix for the window before
  LiveView connects (a first drag becoming a text selection) must not come back on an uncached first visit. The
  public file therefore keeps a catcher of about 0.2 KB min+gz: a capture-phase `pointerdown` on
  `[data-box-area]` refuses `selectstart` until the pointer is released and stores the press, its last move and
  its release (`window.__pkEarlyPress`); the admin file takes it over when it runs (`startBoxSelect`, then
  synthetic `pointermove`/`pointerup` at the stored positions through the same code; a released box waits in
  `__pkPendingBox` for the hook). Nothing of the box logic is duplicated in the public file. Limits: nothing is
  drawn before the admin file arrives (the early start narrows that window; a host layout without
  `data-pk-admin` has none), the replay uses the geometry as it is at takeover (a scroll in between moves the
  box), a press older than 10 s or on a detached page is dropped, and a press on a card, link or button is
  kept but starts no box (`startBoxSelect` decides).
- **A first-mount flash** on admin pages that change layout in `mounted` (`TableFit`, `RowMenuAuto`,
  `CrumbSwitcher`, `SortableGrid`): only the first admin page of a session; reduced by the early start; later
  pages resolve the cached promise in a microtask, before paint.
- **Lost `push_event` during the load window** for a stubbed hook that listens with `handleEvent` and is pushed to
  at mount. The hooks that do so are audited in step 2; any that matters stays public.
- **`window.Chart`** is no longer present at load (only `EmailCharts` used it, in this tree and in every sibling
  module checked).
- **Hosts that never ran `phoenix_kit.update`** and do not compile with the js_sources compiler keep a bundle with
  no admin file. The failure is reported to admins by the library notice and by `phoenix_kit.doctor`; it is the same
  contract the viewer libraries already have.
- **Consent duplication** (not touched here): `CookieConsent` (~32 KB of the public file) is duplicated by the
  legal module's own bundle, which replaces it at load.

## Open questions

1. Module scope (section 7): this branch or a follow-up, and who changes the module repositories?
2. Core's own consent code duplicates the legal module's; with the module installed it is dead weight in the public
   file. Remove (needs a decision about hosts without the module) or leave?
3. A host that includes `phoenix_kit.js` both ways (script tag and `import`) pays for it twice, and one that
   also loads the consent script by several routes pays for that too — a host-side cleanup, outside this branch.
4. Can the head run a browser pass for the admin checks above?
