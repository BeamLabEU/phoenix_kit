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
| — the 72 hooks and helpers at the time of measuring (lines 21–end, hand-written, never minified) | 555 777 | 155 968 | 203 053 | 58 723 |
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
cost one request. With the bundle already loaded the real `mounted` runs in the same turn as the stub's, not after a
microtask: LiveView mounts the hooks of a diff and dispatches the diff's events in one synchronous stack, and a
`handleEvent` registered a turn later misses them. A failed load reports through the existing library notice, and LiveView
mounts a hook once per element, so the stub that was refused or failed is kept by the page and retried: after the pause
that follows a failure (4 s), then at doubling intervals up to a minute, for as long as one still waits; whichever request gets
the bundle (a retry or another hook's mount) mounts all of them, and a stub destroyed meanwhile is dropped. A bundle that arrives
but throws while it runs is not retried: the retry is for a request that failed, and running the file again would repeat its
top-level code (a document listener each time) and fail the same way, so that is reported and final for the page. A hook whose
own `mounted()` throws is reported by name and does not stop the stubs behind it.

Because **every name stays in `PhoenixKitHooks`**, nothing a host (or an external module) already references can
become an "unknown hook", and the classification below only decides *performance*, never *correctness*: a hook
sorted into the wrong list costs a lazy request on a page that did not need it, or bytes on a page that did not.

Known limits, accepted and documented: `updated` calls and `push_event`s that reach a stubbed hook in the window
between its mount and the bundle's arrival are not replayed (`real.mounted` reads the DOM as it is then). That
window is only until the bundle arrives, i.e. the first admin page of a session, and it is narrowed in practice by an **early start**: the admin
layout (`LayoutWrapper`) carries a marker attribute and `phoenix_kit.js` starts the download at
`DOMContentLoaded` when it finds it, i.e. before the socket has joined. The marker is an optimisation, not a
requirement. The early start needs the install facts, which a host that defers both tags may not have yet when it runs
(`phoenix_kit.js` first, a slower `phoenix_kit_modules.js` after it); asking then used to report a failure that was only lateness
and to open the pause that refused the first real mounts. With no facts the early start now does nothing, tries again when the
document has been parsed (after every deferred script), and a failure for missing facts opens no pause, since no request was
refused. A stub that mounted before the facts arrived is kept and retried like any other (see above).

### 4. What is public and what is admin

Rule: **a hook stays public when core or a known module renders it from a surface that is not the admin area or
the user dashboard, or when it is a global behaviour every page needs; generic small form/UI primitives stay
public (their cost is a few hundred gzip bytes each, less than one lazy request); specialised or heavy hooks go
to the admin bundle.** The split is an explicit list in `phoenix_kit.js` (`ADMIN_HOOKS`), and a node test pins it.

*Public, 38* — LibraryLoadNotice, CookieConsent, FlashAutoDismiss, TimezoneOffset, TimezoneDetector,
LanguageSwitcherSearch, LanguageSwitcherPosition, PkDialog, PkDialogTrigger, PopupLink, ResetSelect,
SelectOnMount, TimeAgo, CopyToClipboard, FadeOut, PreserveScroll, InfiniteScroll, PageSizeAutoFit,
MaintenanceCountdown, PkShiftEnter, PkUrlMirror, PhoenixKitUrlState, PkCheckboxIndeterminate, PkDateInput,
PkChartCrosshair, ViewportPopover, and the five already-lazy library wrappers Leaf, FrescoViewer, FrescoCanvas,
TesseraLayer, EtcherLayer; MentionInput, UploadStats and UploadGuard, which core's own `file_upload` component
and its mention-enabled text fields render, so a module's public page (a form with an upload, a comment box) has
them; AudioRecorder, the microphone behind `<.audio_recorder>` (3.4.0); and PasskeySignIn and PasskeyRegister,
the passkeys of the sign-in page and of the Security tab of the account settings (see the end of this section);
and Turnstile, the Cloudflare bot check that core renders on its sign-up, magic-link, confirmation and password-reset forms.

*Admin, 41* — SortableGrid, MediaImageZoom, MarkdownEditor, InstantViewer, ViewerKeydown, ViewerPaneFit,
MediaViewerDialog, ViewerSwipe, ViewerGallery, ViewerHiresLoading, AnnotationBurn, EtcherTooltipActions,
AnnotationComposerPosition, EtcherReset, StackMemory, StackExpand, WaveformPlayer, MediaDragDrop,
FolderDropUpload, UploadResume, UploadManager, RemovalModal, ContextMenu, AvatarCrop, ImageEditor, SearchPicker,
PkDialogDraft, PkHashHighlight, BulkSelectScope, TableLocalSearch, TableFit, TableCardView, RowMenu,
RowMenuAuto, ListFilter, TreePickerSearch, CrumbSwitcher, AdminSidebarScroll, IntegrationPickerSearch,
EmailCharts, NavTabsOverflow.

`UploadManager` (the upload manager of #1006, a queue and panel for any LiveView upload) is admin by the same rule:
core renders it in the media browser, its pickers and the selector page and nowhere else, and no known module puts
it on a public page. Its script is also a standalone file for projects outside PhoenixKit
(`phoenix_kit_upload_manager.js`), of which `phoenix_kit_admin.js` holds a copy, identical but for the lines that
register the hook (`PhoenixKitAdminHooks` instead of `PhoenixKitHooks`; `upload_manager_bundle.test.cjs`). Public, it
would have been 55 KB raw / 8.2 KB min+gz more in every page's file (303 603 B raw when measured, over the 256 KiB
budget it had then, and over today's 288 KiB as well).
Behind a stub it has the limit of every stub, and one more cost: the manager registers the chunked uploader
(`PkChunked`) when it starts, and a file chosen before the bundle has arrived is preflighted regardless, so the stub
of `UploadManager` keeps a stand-in under that name (`holdChunkedUploader`) which takes the entries LiveView hands
it, waits for the bundle and passes them on, or fails them when the bundle does not come. It also uses the second
argument LiveView gives every uploader, `onError(callback)`, whose callback runs when the channel of the join that
preflighted the entries errors (the socket drops, the process dies; `view.ts` and `live_uploader.js` of LiveView 1.2). From
then on the entries belong to a process that is gone, and what is pushed for them fails that process (an upload it does not
know) or is ignored (an entry it does not know of an upload it does): one still waiting in the stand-in is dropped with a
console warning, neither started nor failed (a failed mark is a push too), and one the real uploader is already sending
is stopped (`chunked.stop`, which leaves the partial file on the server). The callback is per call, so it does not depend
on which panel's stub installed the stand-in; a drop that finds nothing sending, or a job already done, stops and says nothing.
The stand-in leaves when the bundle arrives through any stub: the stub whose own request failed cannot take it away, so
the stub the real hook is mounted for does (`releaseStandIn`), and the manager's first file never passes through it. Every `UploadManager` stub also keeps the connection state LiveView reports
(a stub has no `disconnected` / `reconnected` of its own, and LiveView calls them only on the hook instance it made) and
tells the real hook once it has mounted, so a bundle that arrives during an outage starts the manager offline instead of
feeding a file to a dead socket. `UploadResume` (the browser's stash of picked files, which #1011 makes send them again by
themselves after a reload) is admin as well; the stash is read only once the bundle is here, and the resumed file reaches the
real uploader because the bundle replaces the stand-in in the turn the hooks mount, before any preflight reply (the real
`UploadResume` may mount a moment before the replacement, but its report goes to the server and back first)
(`upload_resume_reload.test.cjs`).

At design time the public hooks were estimated at ~107 KB of ~507 KB of hook code. **As built** (esbuild 0.25.4
`--minify`, `gzip -9 -n`): `phoenix_kit.js` is 292 711 B raw, 83 005 gzip, 110 876 minified, 33 964 minified + gzip;
`phoenix_kit_admin.js` is 448 676 / 126 104 / 169 504 / 49 467. The size budget in `admin_split.test.cjs` (288 KiB for
the public file) is a coarse backstop; what keeps an admin hook out of the public file is the name check in the same
test.

`AudioRecorder` (the `<.audio_recorder>` of 3.4.0, a microphone recorder "any page can use") is public by the rule above:
a generic form primitive, imported into every page's helpers next to `file_upload`, and documented with a public
form as its example, so a page that renders it must not wait for the admin bundle (48 KB min+gz, against the hook's
own 2.3 KB). Core renders it nowhere itself and no known module puts it on a page yet. It added 13 087 B raw (the hook and its line in the header) /
2 032 B min+gz to the public file at 3.4.0, and 2 677 B raw more with the follow-up of #1023 (the recorder started from
a page's own button, a clip joining a page's own upload), which is why the budget went from 256 to 272 KiB (the test says so; it went to 280 KiB later as deliberate headroom for the next public hook from main: 2.4 KB were left under 272 when it was raised, and the fixes that followed took the file past 272 KiB on their own; and to 288 KiB with main's passkey hooks, below); its body is
main's, character for character. A lazy chunk of its own, the other way to keep it off pages without a
recorder, would cost a third vendored file (compiler, facts, doctor) for those 2 KB.

The last merge with main brought three more things to classify. The eye button of
`<.input password_toggle>` is not a hook but a `submit` listener on `document` (`hideRevealedPasswords`) that presses a
revealed field's button again before the form is sent, so the browser's form history and the password manager see a
masked field. Core's own login, registration, magic-link, reset-password and confirmation pages carry the toggle, so the
listener is public (1 259 B raw): in the admin file it would not exist on the pages that need it. `AvatarPeek` (a
larger copy of a small avatar under the pointer, 3 656 B raw) is a `document` listener too, and admin: core sets `peek`
only on the users table and the live sessions page, whose layout starts the download at `DOMContentLoaded`
(`data-pk-admin`), so the listener is there without any hook mounting. Its known limit is that `peek` is an ordinary
attribute of a core component: a page outside the admin area and the dashboard that sets it shows no preview, because
that page never loads the bundle (the preview is decoration, so nothing else breaks). `AvatarCrop`'s newer zoom-out
code (`avatarCropMinZoom`, the site's shape as `data-fit`) moved into the admin file with the hook.

The same pass classifies the **non-hook top-level code** (the collapse scroll keeper, the change cue, the global
textarea / stray-click / unsaved-changes listeners, the Etcher tooltip bridges): code that runs for every page
stays public, code that only serves admin hooks moves with them. One piece of an admin hook has to run earlier than its bundle: the
admin menu is restored by `phoenix_kit.js` once a full page load has been parsed (the bundle is requested at `DOMContentLoaded`
at the earliest, and a menu painted at the top would jump): the saved offset, and the current page's link centred when nothing
is saved or the offset hides it (about 0.3 KB minified). The admin hook calls that same function through `PhoenixKitInternals`
on a live redirect, and the save side stays in the admin file. A helper used from both sides stays public and is
handed to the admin bundle through a private `window.PhoenixKitInternals` object — the admin file is a plain
script and cannot see the public file's closure. Which helpers those are is found mechanically: a TypeScript
`checkJs` pass over each file lists every identifier it uses and does not define (it reports exactly two on today's
file — the `define` of Chart.js' UMD wrapper and the `Chart` global), so a forgotten helper shows up as a named
error, not as a runtime `ReferenceError` in a browser.

**The passkey hooks** (`PasskeySignIn`, `PasskeyRegister`: main's block, byte for byte, 9 340 B raw / 1 205 B min+gz) are
public. `PasskeySignIn` is rendered by the sign-in page (`login.html.heex:121`), before anyone is signed in, and starts
the browser's passkey suggestions as it mounts. `PasskeyRegister` (`live/components/passkeys.ex:236`) is rendered by the
`:passkeys` section of `UserSettings` (`user_settings.ex:1614`; the Security tab, `profile_settings_tabs.ex:61`), which
`Live.Users.ProfileSettings` shows through `LayoutWrapper.app_layout` (`profile_settings.html.heex:1`): the host's own
layout, not the admin chrome (`admin_page?` looks at the path, `layout_wrapper.ex:356`) and not the dashboard layout, and
without `data-pk-admin` (`layout_wrapper.ex:1313`, `layouts/dashboard.html.heex:169`). A host can also embed
`UserSettings` on a page of its own. The admin user page renders the same component (`user_details.html.heex:420`) and it
works there because the public file loads on every page. Admin was the alternative for `PasskeyRegister` (a stub, 2 955 B
moved into the admin file, its helpers shared with the sign-in hook through `PhoenixKitInternals`): it would have saved
226 B min+gz per page, and cost a visit that opens the Security tab directly a download of the 122 KB gzip admin bundle for one
button, a click lost before the bundle arrives, and no way to add a passkey on a host whose install facts are missing. It is a
flow of account security, not a specialised hook. `AvatarCrop`, on the Account tab of the same page
(`user_settings.ex:1065`, `avatar_editor.ex:362`), stays admin: 13 158 B raw of a hook only that editor uses. The two
passkey hooks are why the budget is 288 KiB.

**`NavTabsOverflow`** (the opt-in `overflow={:menu}` of `<.nav_tabs>`, #1024: 13 294 B raw, 1 453 B min+gz) is admin, behind a
stub, because nothing outside the admin area renders it. The hook is attached only by the `:menu` branch of `nav_tabs/1`
(`nav_tabs.ex:221`, `phx-hook` on `:239`); the default `:wrap` renders none. No call in `lib/` sets `overflow`: of the 19 call sites of
`<.nav_tabs>`, the ones outside the admin area (`profile_settings_tabs.ex:306`, `library_preferences.ex:220`) do not, and the
other mentions are the moduledoc example and the tests (the review of #1024 says "no core page opts in yet"). It is not
`AudioRecorder`, whose changelog entry says any page can use it: this is an opt-in mode that nobody has opted into. Public, it
would have taken the public file to 301 847 B (over the 288 KiB budget by 6 935 B) for a hook no page uses. The condition for
changing this is written once: **the first change that sets `overflow={:menu}` on a page outside the admin area and the user
dashboard (`profile_settings_tabs`, say) moves the hook into `phoenix_kit.js` in the same commit**, with a new budget if it
needs one, because the dead render of the strip is a single clipped row and a stub would prolong that until the admin bundle
arrives. On an admin page the layout's `data-pk-admin` starts the download early, so it works there as every admin hook does.

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
292 711 B raw / 83 005 gzip readable, 33 964 B gzip minified, the mention field, the two upload hooks, the audio recorder,
the passkey hooks and the Turnstile widget being public; the admin bundle is 448 676 B / 126 104 gzip readable, 49 467 B gzip minified;
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
   existing `test/js` files that exercise admin hooks are pointed at the file that now holds what they test (as built:
   28 of main's 52; there were 39 test files when this was written).
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
  synthetic `pointermove` (with `buttons: 1`: a box ends on a move that reports no button) and `pointerup` at the stored
  positions through the same code; a released box waits in
  `__pkPendingBox` for the hook). Nothing of the box logic is duplicated in the public file. Limits: nothing is
  drawn before the admin file arrives (the early start narrows that window; a host layout without
  `data-pk-admin` has none), the replay uses the geometry as it is at takeover (a scroll in between moves the
  box), a press older than 10 s or on a detached page is dropped, and a press on a card, link or button is
  kept but starts no box (`startBoxSelect` decides).
- **A first-mount flash** on admin pages that change layout in `mounted` (`TableFit`, `RowMenuAuto`,
  `CrumbSwitcher`, `SortableGrid`, `NavTabsOverflow`): only the first admin page of a session; reduced by the early start; later
  pages mount the real hook in the stub's own turn, before paint.
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
