# Claude Review — PR #1047

**Reviewer:** Claude Opus 5.5
**PR:** Add offline annotating to the media viewer, opt-in (alexdont)
**Reviewed:** 2026-11-19 (merged into `main` in the 2026-11-19 PR sweep)

## Findings

### BUG - MEDIUM — the service worker could 404 in dev (fixed)

`AssetsController.serve/2` served `etcher-offline-sw.js` only when
`function_exported?(Etcher, :offline_worker, 0)`. `function_exported?/3` does not load the module.
In interactive mode (dev, test) Etcher is loaded only once something else has called it, so a
fresh boot answered the worker's registration with a 404 until a viewer page had rendered.
The etcher floor is `~> 0.29.0` (#1045), which always has `offline_worker/0`, so the guard
protected nothing. It is gone; the worker is served whenever `PhoenixKit.Offline.enabled?/0`.

## Checked

- **Writes still go through the server's checks.** An offline device's saves arrive through the
  same `handle_event` as online ones: `annotation_file_writable?/2` and the managed-library check
  run again, so losing the right to annotate while offline cannot be bypassed.
- **Read-only viewers keep nothing.** `offline_key/2` is nil unless `can_annotate` and the switch
  is on, so no `data-offline-*` marker is rendered for them.
- **`saved_reply/1`** replies `%{saved: false}` only when a write or delete failed, and resets the
  flag. Etcher reads any other reply as "stored", so the online behaviour is unchanged.
- **`display: contents` wrapper.** The template diff is mostly re-indentation under the new
  wrapper. The branches (plain / burned / live) and their ids are unchanged.
- **Worker headers.** `cache-control: no-cache`, so a new worker is picked up, and
  `service-worker-allowed: /`. The URL carries no locale (`Routes.path/2` with `locale: :none`),
  so one registration serves every language.

## Open (accepted by the PR, worth a follow-up)

- **Signing out does not clear the device's copies.** The service worker keeps the pages and
  pictures an annotator opened. On a shared computer, the next person can open them offline from
  the cache. That is acceptable while the feature is opt-in (`offline_annotations: true`), but a
  host that turns it on for shared devices needs the follow-up first: clear the caches on
  sign-out.
