# Public and admin JavaScript

PhoenixKit's browser code is split so that a public page loads only the part it needs.

| File | What is in it | When it loads |
|---|---|---|
| `phoenix_kit.js` | the shared library loader, the hooks a public page can render, and a **stub** under the name of every admin hook | on every page, as before |
| `phoenix_kit_admin.js` | the real code of the admin and user-dashboard hooks | on the first mount of any admin hook, once |
| Chart.js 4.5.1 (`priv/static/assets/vendor_libs/chartjs/`) | the library the email dashboard draws with | when `EmailCharts` first mounts |

The design and its reasoning are in the repository: `dev_docs/plans/2026-10-27-public-admin-js-split.md`.

## How a host upgrades

Nothing in the host's code changes. `mix deps.update phoenix_kit`, then `mix compile` — the
`:phoenix_kit_js_sources` compiler runs on every compile and vendors, under
`priv/static/assets/vendor/`:

- `phoenix_kit.js` and `phoenix_kit_modules.js` (the install facts and the module bundles), and
- `lib/admin-<version>-<hash>.js` — the admin bundle, named in `window.PHOENIX_KIT_LIBS.admin`.

A host without the compiler, or one that only `import`s `phoenix_kit.js` into its `app.js` and has
never had the facts script tag (`vendor/phoenix_kit_modules.js`) in its root layout, runs
`mix phoenix_kit.update` once: that vendors the files and adds the tag. Without the facts the browser
does not know the admin bundle's file name, and the admin hooks do nothing (the viewer libraries
already need the same facts).

A host that `import`s `phoenix_kit.js` into `app.js` and spreads `window.PhoenixKitHooks` into
`LiveSocket` keeps doing exactly that. Every hook name is still in `window.PhoenixKitHooks`: the admin
ones are stubs that load the admin bundle, then become the real hook on the LiveView's own hook
instance (`this.el`, `this.pushEvent`, `this.handleEvent` all work), so an admin page never reports an
unknown hook. `mix phoenix_kit.doctor` **warns** when the facts name no admin bundle or the file is not
on disk.

`phoenix_kit_admin.js` is not meant to be included by hand: it needs the helpers `phoenix_kit.js`
shares with it and runs after it, and the stubs load it themselves. (The copy under `deps/` holds
core's hooks only; the one the compiler writes to `vendor/lib/` also carries the admin bundles of
modules.) A host that overrides an admin hook in its own `LiveSocket` hooks — for instance
`{...window.PhoenixKitHooks.RowMenu, updated() {…}}` — gets the stub plus its `updated`; once the bundle
has loaded, the real hook's callbacks are set on the hook instance and replace a same-named callback of
the override. Such an override does not survive for the callbacks the real hook defines.

## Where the browser finds the files

In this order:

1. **`window.PHOENIX_KIT_LIB_BASE`** — set by the host itself, or by `config :phoenix_kit,
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
`{:ok, binary}` or `{:error, reason}`; any other answer counts as a failed minify). Minifying an
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
an upload form, a comment box.) Everything else goes in
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
Marking the page's layout with `data-pk-admin` starts the download while the socket connects. Keeping these
hooks public instead would add at least 10 KB (minified, gzipped) to every public page.

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
| admin page renders, sortable lists / tables / editors do nothing, console: "The … hook did not start: the admin bundle could not be loaded" | the file named in the facts is missing, blocked by the page's CSP, or served from another URL than the library base points at. `mix phoenix_kit.doctor`; see "Where the browser finds the files". Every later mount asks again, so a transient failure heals on the next admin page. |
| console: "phoenix_kit_admin.js must load after phoenix_kit.js" | `phoenix_kit_admin.js` ran before `phoenix_kit.js`. |
| console: "The admin hook X has no stub in phoenix_kit.js" | a hook was added to the admin file without being added to `ADMIN_HOOKS`. |
| console: "The admin bundle loaded but defines no hook named X" | X is a module's hook that its `hooks:` list names but its bundle does not export under that name, or `phoenix_kit.js` and the admin bundle are from different PhoenixKit versions. |
| the bundle is large in production | esbuild was not installed when the release was compiled: run `mix assets.setup`, then `mix compile`. |
