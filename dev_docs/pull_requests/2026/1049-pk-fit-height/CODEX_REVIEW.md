# PR #1049 — Overlay height

Reviewed the merged hook and its scrollport follow-up through `050844355`.

**BUG - MEDIUM.** On a content-box overlay, the hook assigned the entire available height to the content. Vertical padding and borders then extended past the requested margin. The calculation now subtracts those edges before applying the element's own CSS ceiling. A hook regression test covers both the available-room limit and a smaller CSS ceiling.

All 20 hook tests passed. In headless Chromium, a padded, bordered content-box overlay inside a 300px scrollport left the configured 8px gap. The project precommit gate passed.
