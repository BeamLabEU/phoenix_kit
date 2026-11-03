# PR #993 — Add an external picker option to MediaGallery

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve, docs clarified

## Checked and sound

- `open_picker`, `remove_image` and `reorder_images` are refused on the server when `readonly`; the
  external `open_picker` asks the host nothing at the limit (a full `:single` gallery, `max_count`
  reached), matching the hidden Add tile.
- The built-in picker never mounts with `external_picker`; the reply goes through the existing
  `update(%{media_selected: …})` clause with the `mode`/`max_count` clamp, then `{:changed, …}`.
- Trust: the uuid list arrives through the host's own server code (`send_update`), the same trust level as
  the `selected` attr the host already passes; a client cannot forge it.
- `external_picker` defaults to false via `assign_new`; no new strings or forms. The integration test
  drives the real cycle (click → `{:open_picker}` → `send_update` → `{:changed}`).

## Findings

- **NITPICK — images only was not stated (documented).** The built-in picker is locked to images; the
  gallery does not filter `media_selected`, so a host picker returning a PDF renders a broken thumbnail.
  The "External picker" section now says to return image files only.
- **NITPICK — a reply built from `request.selected` can revert newer edits (documented).** It is a snapshot
  from the click; a remove/reorder made while a non-modal host picker is open is undone by a reply built
  from it. The moduledoc now says to build the reply from the selection the host holds now.
