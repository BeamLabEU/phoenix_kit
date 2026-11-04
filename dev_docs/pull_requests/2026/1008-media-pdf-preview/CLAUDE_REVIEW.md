# PR #1008 — Fix the PDF preview in Chrome: no sandbox on the media viewer's PDF iframe

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one follow-up left open

Removes `sandbox="allow-same-origin"` from the media viewer's PDF iframe, because Chrome's built-in PDF
viewer does not run in a sandboxed frame, and gives the iframe an id through `viewer_dom_id/2`.

## Checked and sound

The sandbox was a real control, so each claim that replaces it was checked in the code:

- **Nothing that can run is served inline.** `FileController.disposition_for/1` allows only
  `@inline_types` (raster images, `application/pdf`, `text/plain`) plus `video/*` and `audio/*`. HTML,
  XHTML, SVG, XML, JS and CSS are `attachment`.
- **`nosniff` is on the file route.** `put_content_headers/4` sets it next to the disposition, and
  `send_unedited/4` sets it for the unedited original.
- **A false claim fails closed.** The branch keys on `f.mime_type == "application/pdf"`, which is the
  uploader's claim, but the file is then served with that same type and `nosniff`, so HTML bytes claimed
  as a PDF end in a viewer error and never in a page in the admin origin. A public bucket's URL is
  cross-origin to begin with.
- **This was the only sandbox of its kind.** The other `sandbox` in `lib/` is the empty one on the email
  preview's `srcdoc` iframe (`email_preview.html.heex`), which stays. It frames HTML, so it must.
- **The test pins both forms** of the attribute, so it fails if `sandbox` comes back.

## Findings

### NITPICK — a `%PDF-` check at upload (not fixed)

Upload sniffing corrects raster claims only, so `application/pdf` stays the uploader's word. The PR names
this itself. It is not a hole today: the worst outcome is a viewer error, for the reasons above. It would
turn that error into a type that is true at upload. Left out because it changes what the upload path
accepts, which is a separate decision from a viewer fix.
