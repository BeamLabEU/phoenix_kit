# Cally 0.9.2 (vendored)

The calendar popup of `<.date_input>` (`PhoenixKitWeb.Components.Core.DateInput`,
hook `PkDateInput`). Served from the host's own origin by PhoenixKit's
`:phoenix_kit_js_sources` compiler (copied to
`priv/static/assets/vendor/lib/cally-0.9.2-<hash>.js`) and loaded with a dynamic
`import()` the first time a calendar is opened, so no page pays for it until
then and no third-party request is made.

- Upstream: https://github.com/WickyNilliams/cally — licence MIT (`LICENSE`, unchanged)
- Source: npm `cally@0.9.2`, `https://registry.npmjs.org/cally/-/cally-0.9.2.tgz`
- Tarball integrity (matches the registry record):
  `sha512-zY/Ueh+p6O+LKPYqNB13dATgNuazAHS0n3JbtKyUmMoQfRq5mC2/zFI3UV2X3g+2lZn2BBwr1Z+HxyG9Dt/6lw==`
- File: `package/dist/cally.js`, unmodified, sha256
  `4dcba6a3b8ec63b66ff2fbfc6cf47b7dee1eb4896eac89fe7487d82e28e15870`
- Checked self-contained: no static or dynamic imports of other files and no
  workers, so the one file is the whole library. Importing it defines the
  `calendar-date`, `calendar-month`, `calendar-range`, `calendar-multi` and
  `calendar-select-*` custom elements.

Updating it is a deliberate core change: replace the file, update the version,
checksum and path in `PhoenixKit.Install.ViewerLibraries`, and this README.
The checksum is enforced by a test.
