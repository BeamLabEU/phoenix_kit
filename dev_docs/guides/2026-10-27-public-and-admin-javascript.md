# Public and admin JavaScript

PhoenixKit's browser code is two files, and a public page loads only the first.

| File | What is in it | When it loads |
|---|---|---|
| `phoenix_kit.js` | the shared library loader, the hooks a public page can render, and a **stub** under the name of every admin hook | on every page, as before |
| `phoenix_kit_admin.js` | the real code of the admin and user-dashboard hooks | on the first mount of any admin hook, once |
| Chart.js 4.5.1 (`vendor_libs/chartjs/`) | the library the email dashboard draws with | when `EmailCharts` first mounts |

Design and reasoning: `dev_docs/plans/2026-10-27-public-admin-js-split.md`.

## How a host upgrades

Nothing in the host changes. `mix deps.update phoenix_kit` and `mix compile` (the
`:phoenix_kit_js_sources` compiler runs on every compile), or `mix phoenix_kit.update` for
a host without the compiler. Both vendor, under `priv/static/assets/vendor/`:

- `phoenix_kit.js` and `phoenix_kit_modules.js` (the install facts and the module bundles), and
- `lib/admin-<version>-<hash>.js` — the admin bundle, named in `window.PHOENIX_KIT_LIBS.admin`.

A host that `import`s `phoenix_kit.js` into its own `app.js` and spreads
`window.PhoenixKitHooks` into `LiveSocket` keeps doing exactly that. Every hook name is still
in `window.PhoenixKitHooks`: the admin ones are stubs that load the admin bundle, then become
the real hook on the LiveView's own hook instance (`this.el`, `this.pushEvent`,
`this.handleEvent` all work), so an admin page never reports an unknown hook.
`mix phoenix_kit.doctor` fails the check when the facts name no admin bundle or the file is
not on disk.

A host that wants the admin hooks without the lazy request (an offline or CSP-strict build)
may `import` `phoenix_kit_admin.js` in its `app.js` after `phoenix_kit.js`; the stubs then
find it loaded and fetch nothing.

## Where the browser finds the files

The facts file puts `window.PHOENIX_KIT_LIB_BASE` on the page: the URL the `vendor/lib/`
directory is served from. It is `/assets/vendor/lib/` unless the host configures otherwise,
so it does not matter where `phoenix_kit.js` or the facts file are served from. A value the
host sets on `window` itself wins, whenever it sets it.

```elixir
# config/config.exs — only for a host whose static assets are not served at /assets/…
config :phoenix_kit, library_base_url: "https://cdn.example.com/assets/vendor/lib/"
```

`library_base_url` also covers the CDN recipe: serve `priv/static` from the CDN and name the
CDN's URL of `vendor/lib/` here; the viewer libraries and the admin bundle follow.

## Minified output

In production (`Mix.env() == :prod`, or `config :phoenix_kit, minify_libraries: true`) the
compiler minifies the vendored `phoenix_kit.js`, `phoenix_kit_modules.js` and the admin bundle
with the host's own esbuild — the binary `mix assets.setup` installs, so run it before the
compile that builds the release. Without that binary, or when the transform fails, the readable
files are served and the compile says so; it never fails the build. `config :phoenix_kit,
js_minifier: {Mod, :fun}` names another minifier (one argument, returns `{:ok, binary}` or
`{:error, reason}`). Minifying an already minified file is harmless, so a host that runs the
vendored files through its own esbuild profile as well loses nothing.

## `window.Chart`

`phoenix_kit.js` used to define `window.Chart` on every page. It no longer does; Chart.js
loads when the email dashboard needs it. A host that draws its own charts asks for it:

```js
window.PhoenixKitLibraries.chartjs().then(function (Chart) { /* … */ })
```

The promise resolves to `window.Chart` (a copy the host already provides is used as it is),
and rejects once the failure has been reported to the console and, for admins, the page notice.

## Writing a hook in core

A new hook goes in `phoenix_kit.js` only if a page outside the admin area and the user
dashboard can render it — a generic form or UI primitive, or something every page needs.
Everything else goes in `phoenix_kit_admin.js`, registered as
`window.PhoenixKitAdminHooks.Name = { … }`, and its name is added to `ADMIN_HOOKS` in
`phoenix_kit.js`. `test/js/admin_split.test.cjs` pins the two lists to each other: a name in
one place only fails it. Hooks must not assume the admin bundle is loaded when a page is
rendered; a callback that reaches a stubbed hook before the bundle arrives (`updated`,
`beforeUpdate`, `disconnected`, `reconnected`) is dropped, and `mounted` reads the DOM as it is
when it finally runs.

Helpers both files need stay in `phoenix_kit.js` and reach the admin file through
`window.PhoenixKitInternals` (private; not an API).

## Module bundles

A module's `js_sources/0` entry is public unless it says otherwise. A bundle that only admin
pages use says `scope: :admin, hooks: ["Name", …]`: the compiler leaves it out of
`phoenix_kit_modules.js`, appends it to the admin bundle, and writes a stub under each listed name
into `phoenix_kit_modules.js` (whichever of that file and `phoenix_kit.js` runs first). Every
listed hook is a plain object of callbacks, and the list must name every hook the bundle exports:
an unlisted hook can never be mounted. Two admin bundles may not list the same name (compile
error). Details and the limits of a stubbed hook: `PhoenixKit.Module.js_sources/0`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| admin page renders, sortable lists / tables / editors do nothing, console: "The … hook did not start: the admin bundle could not be loaded" | the file named in the facts is missing, blocked by the page's CSP, or served from another URL than `library_base_url` says. `mix phoenix_kit.doctor`. |
| console: "needs phoenix_kit.js loaded first" | `phoenix_kit_admin.js` ran before `phoenix_kit.js`. |
| console: "The admin hook X has no stub in phoenix_kit.js" | a hook was added to the admin file without being added to `ADMIN_HOOKS`. |
| the bundle is large in production | esbuild was not installed when the release was compiled: run `mix assets.setup`, then `mix compile`. |
