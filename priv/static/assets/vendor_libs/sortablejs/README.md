# SortableJS 1.15.0 (vendored)

Served from the host's own origin by PhoenixKit's `:phoenix_kit_js_sources`
compiler (copied to `priv/static/assets/vendor/lib/sortable-1.15.0-<hash>.js`),
so sortable lists and Etcher's Customise dialog need no third-party request.
See `dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md`, Part B1.

- Upstream: https://github.com/SortableJS/Sortable — licence MIT (`LICENSE`, unchanged)
- Source: npm `sortablejs@1.15.0`, `https://registry.npmjs.org/sortablejs/-/sortablejs-1.15.0.tgz`
- Tarball integrity (matches the registry record):
  `sha512-bv9qgVMjUMf89wAvM6AxVvS/4MX3sPeN0+agqShejLU5z5GX4C75ow1O2e5k4L6XItUyAK3gH6AxSbXrOM5e8w==`
- File: `package/Sortable.min.js`, unmodified, sha256
  `8a9889aecc2f011e15031fed87eeb35ac75e62655a7b4889ba247ee8ea872474`
  (byte-identical to `https://cdn.jsdelivr.net/npm/sortablejs@1.15.0/Sortable.min.js`)
- A self-contained UMD build: no relative imports or other assets.

Updating it is a deliberate core change: replace the file, update the version,
checksum and path in `PhoenixKit.Install.ViewerLibraries`, and this README.
The checksum is enforced by a test.
