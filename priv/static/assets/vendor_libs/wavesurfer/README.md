# wavesurfer.js 7.12.12 (vendored)

Served from the host's own origin by PhoenixKit's `:phoenix_kit_js_sources`
compiler (copied to `priv/static/assets/vendor/lib/wavesurfer-7.12.12-<hash>.js`)
and loaded with a dynamic `import()`, so the audio waveform needs no
third-party request — and a same-origin module needs no CORS. See
`dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md`, Part B2.

- Upstream: https://github.com/katspaugh/wavesurfer.js — licence BSD-3-Clause (`LICENSE`, unchanged)
- Source: npm `wavesurfer.js@7.12.12`, `https://registry.npmjs.org/wavesurfer.js/-/wavesurfer.js-7.12.12.tgz`
- Tarball integrity (matches the registry record):
  `sha512-fyKNuREQTliCl4b9w7pUzpFXQIkX5tcdYu1o6vBdH+NlUXvTxshvfbG2hj8OxDevzQNZlDTHzZGyAT3FhuutWw==`
- File: `package/dist/wavesurfer.esm.js`, unmodified, sha256
  `1bca765cc75bc4af079ecd1b2edd659b155e5d1715e75a29d68272d9f141f951`
  (byte-identical to what `https://cdn.jsdelivr.net/npm/wavesurfer.js@7/dist/wavesurfer.esm.js`
  served when it was pinned — the bundle used to float on `@7`)
- Checked self-contained: no static or dynamic imports and no workers, so the
  one file is the whole library. Plugins are not vendored; any added later must
  bring their transitive files and an entry in the manifest.

Updating it is a deliberate core change: replace the file, update the version,
checksum and path in `PhoenixKit.Install.ViewerLibraries`, and this README.
The checksum is enforced by a test.
