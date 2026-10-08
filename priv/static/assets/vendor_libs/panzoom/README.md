# Panzoom 4.6.0 (vendored)

Served from the host's own origin by PhoenixKit's `:phoenix_kit_js_sources`
compiler (copied to `priv/static/assets/vendor/lib/panzoom-4.6.0-<hash>.js`),
so the media image zoom needs no third-party request. See
`dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md`, Part B2.

- Upstream: https://github.com/timmywil/panzoom — licence MIT (`MIT-License.txt`, unchanged)
- Source: npm `@panzoom/panzoom@4.6.0`, `https://registry.npmjs.org/@panzoom/panzoom/-/panzoom-4.6.0.tgz`
- Tarball integrity (matches the registry record):
  `sha512-3KxkY1lNKFn98fW5ZFR6vV0YzsXj3I4EQDyFWSXME6/cic86eSS7VjuqIjrA3PEpySo0r5fFtlX8eYCt4JPUFQ==`
- File: `package/dist/panzoom.min.js`, unmodified, sha256
  `7bc8e4ee6bb95a76330b35b392922436cda207acf345e18b4491f62eb0599410`
  (byte-identical to `https://cdn.jsdelivr.net/npm/@panzoom/panzoom@4.6.0/dist/panzoom.min.js`)
- A self-contained UMD build that defines `window.Panzoom`: no imports or other assets.

Updating it is a deliberate core change: replace the file, update the version,
checksum and path in `PhoenixKit.Install.ViewerLibraries`, and this README.
The checksum is enforced by a test.
