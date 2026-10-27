# Chart.js 4.5.1 (vendored)

Served from the host's own origin by PhoenixKit's `:phoenix_kit_js_sources`
compiler (copied to `priv/static/assets/vendor/lib/chartjs-4.5.1-<hash>.js`)
and loaded on demand — by the email dashboard's `EmailCharts` hook the first
time it mounts, or by a host through `PhoenixKitLibraries.chartjs()`. It used
to be pasted into the top of `phoenix_kit.js`, so every page of every host
downloaded and parsed it. See
`dev_docs/plans/2026-10-27-public-admin-js-split.md`.

- Upstream: https://github.com/chartjs/Chart.js — licence MIT (`LICENSE`, unchanged)
- Source: npm `chart.js@4.5.1`, `https://registry.npmjs.org/chart.js/-/chart.js-4.5.1.tgz`
- Tarball integrity (matches the registry record):
  `sha512-GIjfiT9dbmHRiYi6Nl2yFCq7kkwdkp1W/lp2J99rX0yo9tgJGn3lKQATztIjb5tVtevcBtIdICNWqlq5+E8/Pw==`
- File: `package/dist/chart.umd.js`, unmodified, sha256
  `ecc3cd1eeb8c34d2178e3f59fd63ec5a3d84358c11730af0b9958dc886d7652a`
  (byte-identical to `https://cdn.jsdelivr.net/npm/chart.js@4.5.1/dist/chart.umd.js`)
- A self-contained UMD build that defines `window.Chart`: no imports or other assets.
  It ends in a `sourceMappingURL` comment for a map that is not shipped; browsers only
  look at it with the developer tools open.

Updating it is a deliberate core change: replace the file, update the version,
checksum and path in `PhoenixKit.Install.ViewerLibraries`, and this README.
The checksum is enforced by a test.
