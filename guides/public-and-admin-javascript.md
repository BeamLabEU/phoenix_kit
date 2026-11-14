# Public and admin JavaScript

PhoenixKit's browser code is split so that a public page loads only the part it needs.

| File | What is in it | When it loads |
|---|---|---|
| `phoenix_kit.js` | the shared library loader, the hooks a public page can render, and a **stub** under the name of every admin hook | on every page, as before |
| `phoenix_kit_admin.js` | the real code of the admin and user-dashboard hooks | on the first mount of any admin hook, once |
| Chart.js 4.5.1 (`priv/static/assets/vendor_libs/chartjs/`) | the library the email dashboard draws with | when `EmailCharts` first mounts |

The design and its reasoning are in the repository: `dev_docs/plans/2026-10-27-public-admin-js-split.md`.

## How a host upgrades

A host that includes PhoenixKit's JavaScript as it does today changes nothing in its code (the one exception, a host that
extends an admin hook of its own, is described at the end of this section). `mix deps.update phoenix_kit`, then `mix compile` — the
`:phoenix_kit_js_sources` compiler runs on every compile and vendors, under
`priv/static/assets/vendor/`:

- `phoenix_kit.js` and `phoenix_kit_modules.js` (the install facts and the module bundles), and
- `lib/admin-<version>-<hash>.js` — the admin bundle, named in `window.PHOENIX_KIT_LIBS.admin`.

A host without the compiler, or one that only `import`s `phoenix_kit.js` into its `app.js` and has
never had the facts script tag (`vendor/phoenix_kit_modules.js`) in its root layout, runs
`mix phoenix_kit.update` once: that vendors the files and adds the tag. Without the facts the browser
does not know the admin bundle's file name, and the admin hooks do nothing (the viewer libraries
already need the same facts). A host without the compiler in its `:compilers` gets a warning when its router compiles (whether or
not a module ships JavaScript of its own); there is no switch to turn it off, because the compiler is what writes the admin bundle
and the facts that name it, so what silences it is adding the compiler (`mix phoenix_kit.update` does), and a module package, which
has `package:` in its `mix.exs`, is not warned.

A host that `import`s `phoenix_kit.js` into `app.js` and spreads `window.PhoenixKitHooks` into
`LiveSocket` keeps doing exactly that. Every hook name is still in `window.PhoenixKitHooks`: the admin
ones are stubs that load the admin bundle, then become the real hook on the LiveView's own hook
instance (`this.el`, `this.pushEvent`, `this.handleEvent` all work), so an admin page never reports an
unknown hook. `mix phoenix_kit.doctor` **warns** when the facts name no admin bundle or the file is not
on disk, and when the root layout at the installer's own paths (`lib/<app>_web/components/layouts/root.html.heex`, or the
older `templates/layout/`) does not load `phoenix_kit_modules.js` (a tag in a comment does not count; a host that loads the facts another way is told to ignore the warning); a host with another layout is not guessed at.

`phoenix_kit_admin.js` is not meant to be included by hand: it needs the helpers `phoenix_kit.js`
shares with it and runs after it, and the stubs load it themselves. (The copy under `deps/` holds
core's hooks only; the one the compiler writes to `vendor/lib/` also carries the admin bundles of
modules.) A host that overrides an admin hook in its own `LiveSocket` hooks — for instance
`{...window.PhoenixKitHooks.RowMenu, updated() {…}}` — gets the stub plus its `updated`; once the bundle
has loaded, the real hook's callbacks are set on the hook instance and replace a same-named callback of
the override. Such an override does not survive for the callbacks the real hook defines. And until the bundle has loaded the
stub has none of the real hook's methods: an `updated()` of the override that calls one of them (`this.applyMode()` of
`TableCardView`, say) throws a `TypeError` when a patch reaches the element in that window. Guard such a call
(`if (typeof this.applyMode === "function")`), or leave the hook alone and add behaviour from a hook of your own.

## Where the browser finds the files

In this order:

1. **`window.PHOENIX_KIT_LIB_BASE`** — a string, set by the host itself (an element that the page's markup names so, with `id="PHOENIX_KIT_LIB_BASE"`, is not one and is ignored), or by `config :phoenix_kit,
   library_base_url: "…"` (the install facts turn it into that variable without overriding one the host
   set).
2. **Next to the tag that loads `phoenix_kit.js`**, when it is the vendored bundle (`phoenix_kit.js` or the
   digested `phoenix_kit-<md5>.js`): a host serving its assets from a CDN (`static_url`) or under a path
   prefix (`url: [path: "/shop"]`) is right here with no configuration.
3. **`/assets/vendor/lib/`** — the compiler's default, in the facts as `window.PHOENIX_KIT_LIB_BASE_DEFAULT`.
   It applies when no such tag exists, i.e. `phoenix_kit.js` is bundled into the host's `app.js`. It does
   not depend on where `phoenix_kit_modules.js` is served from, so a host that moves, defers or
   re-minifies that file is unaffected.

```elixir
# config/config.exs (or prod.exs) — for a host whose files are not where the tag or the default say
config :phoenix_kit, library_base_url: "https://cdn.example.com/assets/vendor/lib/"
```

`library_base_url` is read **when the compiler runs**, so it belongs in `config/config.exs` or
`config/prod.exs`; from `config/runtime.exs` it has no effect on the file the compiler writes (set
`window.PHOENIX_KIT_LIB_BASE` in the page instead). It also covers a CDN recipe: serve `priv/static` from
the CDN and name the CDN's URL of `vendor/lib/` here.

## Minified output

In production (`Mix.env() == :prod`, or `config :phoenix_kit, minify_libraries: true`) the compiler
minifies the vendored `phoenix_kit.js`, `phoenix_kit_modules.js` (its module bundles; the install facts
stay readable) and the admin bundle with the host's own esbuild — the binary `mix assets.setup`
installs, so run it before the compile that builds the release. Without that binary, or when the
transform fails, the readable files are served and the compile says so once; it never fails the
build. `config :phoenix_kit, js_minifier: {Mod, :fun}` names another minifier (one argument; returns
`{:ok, binary}` or `{:error, reason}`; any other answer counts as a failed minify). The module has to come from a
dependency: the compiler runs before the host's own modules are compiled, so on a clean build one defined in the host's
`lib/` is not there yet, and the note says so instead of asking for esbuild. Minifying an
already minified file is harmless, so a host that runs the vendored files through its own esbuild
profile as well loses nothing.

## `window.Chart`

`phoenix_kit.js` used to define `window.Chart` on every page. It no longer does; Chart.js loads when the
email dashboard needs it. A host that draws its own charts asks for it:

```js
window.PhoenixKitLibraries.chartjs().then(function (Chart) { /* … */ })
```

The promise resolves to `window.Chart` (a copy the host already provides is used as it is), and rejects
once the failure has been reported to the console and, for admins, the page notice.

## Writing a hook in core

A new hook goes in `phoenix_kit.js` only if a page outside the admin area and the user dashboard can
render it — one that core's own code or a known module renders there: a generic form or UI primitive, or
something every page needs. (`MentionInput`, `UploadStats` and `UploadGuard` are public for that reason: core's
`file_upload` component and its mention-enabled text fields render them, and so do the public pages of modules —
an upload form, a comment box. So is `AudioRecorder`: `<.audio_recorder>` is a form primitive any page can use.
So are `PasskeySignIn` and `PasskeyRegister`: core renders them on the sign-in page and on the Security tab of the
account settings, a page in the host's own layout. So is `Turnstile`: core renders it on its sign-up, magic-link,
confirmation and password-reset forms. `NavTabsOverflow`, the opt-in `overflow={:menu}` of `<.nav_tabs>`, is
admin only because no page outside the admin area opts in yet: the first change that sets it on one moves the hook into
`phoenix_kit.js` in the same commit.)
Everything else goes in
`phoenix_kit_admin.js`, registered as `window.PhoenixKitAdminHooks.Name = { … }`, and its name is added to
`ADMIN_HOOKS` in `phoenix_kit.js`. Three places have to agree — the `ADMIN_HOOKS` array, the keys the
admin file defines, and the hook lists in `test/js/admin_split.test.cjs` — and the test fails when they
do not. Hooks must not assume the admin bundle is loaded when a page is rendered; a callback that reaches
a stubbed hook before the bundle arrives (`updated`, `beforeUpdate`, `disconnected`, `reconnected`) is
dropped, and `mounted` reads the DOM as it is when it finally runs.

The media browser's hooks (the cards and their drag and drop, the viewer, the upload stash, the removal
dialog) are admin hooks, and so are the ones of a picker (`MediaBrowser` with `picker`, which modules and hosts
embed in their forms): core itself mounts the browser only on `/admin/media` and `/admin/libraries`. A host
that puts a browser or a picker on a page of its own, outside the admin area and the user dashboard, loses
nothing — the first mount of a stub fetches the bundle — but what the hooks do (the viewer, which stays hidden
until `ViewerKeydown` shows it, the double-click confirm of a single pick, the upload stash, files dropped
from the computer) waits for that one request; picking a card is a plain LiveView click and does not. The
lightbox of `MediaGallery` / `MediaViewer` behaves the same way: `MediaViewerDialog` opens its `<dialog>` in
`mounted`, that is, once the admin bundle has arrived.
Marking the page's layout with `data-pk-admin` starts the download while the socket connects. (The file names come from
`phoenix_kit_modules.js`; when that file has not run yet, as with two `defer` tags and a slower second one, the early start
says nothing and tries again once the document has been parsed, and a mount that finds no facts opens no pause, so the next
one is free to ask.) Keeping these
hooks public instead would add at least 10 KB (minified, gzipped) to every public page.

The upload manager (`UploadManager`, the queue and panel that `<.upload_manager>` renders) is an admin hook
too: core renders it only in the media browser, its pickers and the selector page. Its script,
`phoenix_kit_upload_manager.js`, stays a file of its own for projects that take just that (it registers the
hook in `window.PhoenixKitHooks`, as its guide says); PhoenixKit's pages get a copy of it inside
`phoenix_kit_admin.js`, the same text but for its last lines, which register the hook in
`window.PhoenixKitAdminHooks` (`test/js/upload_manager_bundle.test.cjs` keeps the two in step), behind a stub
in `phoenix_kit.js`. The component comes with `use PhoenixKitWeb, :live_view`, so a host can render it on a page
outside the admin area and the dashboard, and it works there: the queue and the panel start when the admin
bundle has arrived. Files picked before then go to LiveView as they would without the manager (all at once, no
queue, no panel). A resumable upload names the chunked uploader (`PkChunked`), which the manager registers when it
starts; until then the stub of `UploadManager` keeps a stand-in under that name, which takes the files LiveView
hands it, waits for the bundle and passes them on to the real uploader. A file whose entry a LiveView reconnect
orphaned before the bundle arrived (the rejoined process knows nothing of it, and what is pushed for it fails that
process or is ignored) is dropped, not started and not marked failed; the console says so and the person picks it again.
A reconnect while such a file is being sent stops its transfer the same way. A file chosen before the bundle is not in
the browser's stash either: `UploadResume`, which keeps picked files for a reload, is an admin hook too and starts with
the bundle. After a reload it is the same bundle that reads the stash, so the files an earlier page left are reported
and sent again by themselves a moment after the bundle has arrived, through the real uploader; until then the stash is
not touched. A bundle that arrives while the socket is down starts the manager offline: files picked then wait for the
reconnect. **If the admin file cannot be loaded,
uploading in the media browser and the pickers does not work**: the stand-in marks those files failed (and the
console says why), and no panel is shown; with *Resumable uploads* off in Settings -> Media the files go through
LiveView's own uploader all the same, unqueued. `window.PhoenixKitUploadManager` is defined from the bundle's
arrival, not at page load. `data-pk-admin` on such a layout starts the download early.

A gesture whose very first moments must not be lost is the exception, and the media browser's box select is
one: it listens on `document`, and a drag that starts before the bundle has run would select text. For that,
`phoenix_kit.js` holds a small catcher (a primary-button press on `[data-box-area]`: it refuses the text
selection until the button is released and keeps the press as `window.__pkEarlyPress`), and
`phoenix_kit_admin.js` takes the press over when it runs and replays it through the same code, with the page as
it is by then: a press still held gets its box at once, one already released is applied once the hook has
mounted, and a press older than a few seconds or on a page that has gone is dropped. Until the file arrives
nothing is drawn (the admin and dashboard layouts start the download at `DOMContentLoaded`; a host layout of its
own without the `data-pk-admin` marker has no early start, so its window is longer). Only the catcher is
public. A new gesture of that kind does the same: a catcher of a few lines in the public file, the logic in the
admin file.

Two listeners on `document` that are not hooks follow the same rule. The eye button of `<.input password_toggle>` is
public, because its submit listener (`hideRevealedPasswords`) has to exist on the login, registration and password-reset
pages. The larger copy of an avatar under the pointer (`<.user_avatar peek>`, `AvatarPeek`) is admin: core sets `peek`
only on admin pages, and a page outside the admin area and the dashboard that sets it shows no preview, because that
page never loads the bundle (a known limit; the preview is decoration).

The admin menu's scroll position (`AdminSidebarScroll`) is the same kind of case: on a full page load `phoenix_kit.js` puts the
saved offset back as soon as the document is parsed (and centres the current page's link when nothing is saved, or the saved
offset hides it), because the bundle is requested at `DOMContentLoaded` at the earliest and a menu painted at the top would jump;
the admin file keeps the save side and calls the same restore on a live redirect, through `window.PhoenixKitInternals`.

Helpers both files need stay in `phoenix_kit.js` and reach the admin file through
`window.PhoenixKitInternals` (private; not an API).

## Module bundles

A module's `js_sources/0` entry is public unless it says otherwise. A bundle that only admin pages use
says `scope: :admin, hooks: ["Name", …]`: the compiler leaves it out of `phoenix_kit_modules.js`, appends
it to the admin bundle, and writes a stub under each listed name into `phoenix_kit_modules.js`
(whichever of that file and `phoenix_kit.js` runs first). Every listed hook is a plain object of
callbacks, and the list must name every hook the bundle exports: an unlisted hook can never be mounted,
and a listed one the bundle lacks has nothing to mount — the admin bundle says either on the console.
Two admin bundles may not list the same name, nor a name core defines (compile error). Details and the
limits of a stubbed hook: `PhoenixKit.Module.js_sources/0`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| admin page renders, sortable lists / tables / editors do nothing, console: "The … hook did not start: the admin bundle could not be loaded" | the file named in the facts is missing, blocked by the page's CSP, or served from another URL than the library base points at. `mix phoenix_kit.doctor`; see "Where the browser finds the files". The page asks again by itself, after 4 seconds and then at doubling intervals up to a minute, for as long as a hook is waiting, and the hooks that gave up mount when the file arrives; a mount inside the pause is refused at once with the same message. |
| console: "The admin bundle was loaded but failed while running" | the file arrived and threw while it ran, usually because `phoenix_kit.js` and `phoenix_kit_admin.js` are from different PhoenixKit versions (the admin file says so first when it can). This is not retried: running it again would only repeat its top-level code. Run `mix phoenix_kit.update`, then `mix compile`, and reload. |
| console: "The admin hook X is a class or a function" | a module's admin hook is exported as a class; behind a stub it has to be a plain object of callbacks (`{ mounted() {…} }`), which is what `PhoenixKit.Module.js_sources/0` documents. |
| console: "phoenix_kit_admin.js must load after phoenix_kit.js" | `phoenix_kit_admin.js` ran before `phoenix_kit.js`. |
| console: "The admin hook X has no stub in phoenix_kit.js" | a hook was added to the admin file without being added to `ADMIN_HOOKS`. |
| console: "The admin bundle loaded but defines no hook named X" | X is a module's hook that its `hooks:` list names but its bundle does not export under that name, or `phoenix_kit.js` and the admin bundle are from different PhoenixKit versions. |
| the bundle is large in production | esbuild was not installed when the release was compiled: run `mix assets.setup`, then `mix compile`. |
