# PhoenixKit 2.56.0 — release review

Date: 2026-10-07. Reviewer: GPT/Codex.

Reviewed `v2.55.1..v2.56.0`, including PR #910 and the storage changes, their callers,
versioned migrations V210/V211, tests, release notes, dependencies and the actual Hex artifact.
The fixes are prepared locally as **2.56.1**. This review does not publish a package.

## Verdict

Found defects in subject-crop storage and several video rendition settings. Fixed them with
regression coverage. The published 2.56.0 artifact contains these defects; its IP/proxy
changes otherwise follow the documented behavior. No dependency security advisories or
unexpected differences between the tag and package were found.

## Findings and fixes

1. **BUG - HIGH — different focal points overwrite a shared crop object.** Copies of the same
   original share the checksum/directory, and their generated rendition previously used only
   the checksum and rendition name for its object key. Different manual focal points could
   therefore overwrite the bytes served by another copy, while its instance checksum and
   immutable URL described the previous crop. Focus-crop keys now include a fingerprint of
   the point. Existing shared objects continue through the normal reference-checked deletion
   path. The focus spec hash changes so a profile's **Check files** remakes old crops; center
   and proportional rendition hashes remain unchanged.
2. **BUG - MEDIUM — detection and image edits can attach a point to the wrong pixels.**
   `ensure/2` could detect from a downloaded original, then update metadata after an edit
   replaced it. Image edits also retained the previous coordinates after cropping/rotation.
   Automatic writes now lock the file and validate its checksum and original key. The
   generator passes the key it actually downloaded and rechecks both the original and the
   focal point before publishing. An edit clears the old point; the hidden backup preserves
   the unedited point and a revert restores it.
3. **IMPROVEMENT - MEDIUM — changing a point leaves existing crops unchanged.** This was
   a documented limitation in 2.56.0. `put/4` and `clear/1` now invalidate generated focus
   crops and enqueue reconciliation. Other renditions and instances without a spec hash
   (such as burned annotations) are preserved.
4. **BUG - MEDIUM — a decoder exception can escape the fallback through a task link.**
   Detection used `Task.async/1`; rescuing around `Task.yield/2` in the caller does not stop
   the linked task's exception from exiting its caller. Decoder exceptions/exits are now
   caught inside the task. The existing timeout remains. This follows the link behavior
   documented in [Elixir Task](https://hexdocs.pm/elixir/1.19.5/Task.html).
   Optional Vix calls also suppress undefined-module warnings when a host omits Vix;
   compilation and fallback were checked with Vix removed from the code path.
5. **BUG - MEDIUM — accepted height-fixed video/shared renditions are not resized.**
   The schema accepts `fit_by: "height"` and clears width, but FFmpeg handled only width
   and boxes. It now fixes height for video and still-frame output, preserves proportions,
   and avoids enlarging small inputs. Real output tests check the resulting dimensions.
6. **BUG - MEDIUM — preserving the original container ignores quality.** A nil format
   reaches the default quality clause, although the output extension tells FFmpeg which
   container to use. The arguments now infer the format from that extension before choosing
   the encoder/quality options. MP4/MOV CRF output explicitly selects `libx264`.
7. **BUG - MEDIUM — a shared image/video rendition passes image quality as CRF.**
   `applies_to: "both"` accepts the 1–100 scale, but the new video path passed it directly
   to a video encoder. Quality 85 therefore fails H.264 encoding. Shared renditions retain
   the existing image-to-CRF conversion; video-only rows continue to use CRF directly.
   Argument and real-encoding regressions cover both cases.
8. **NITPICK — the new image fixtures assume ImageMagick 7.** They checked `identify`,
   then executed `magick`, failing on ImageMagick 6 installations where the production
   `convert`/`identify` pipeline works. The initial focused run reproduced nine such
   failures. The fixtures now use `convert`, matching production.

## Checked without another finding

- PR #910 port handling, last-forwarded-entry trust, direct-public-peer refusal, mapped
  IPv4 normalization and conditional session rebind, including a lost update race.
- Fingerprint comparison already uses `IpAddress.network/1`, which normalizes mapped
  IPv4: changing its textual representation does not itself break an existing session.
- The rebind remains a deliberate one-time relaxation for sessions stored with a private
  address and reused through a private peer. Its user agent can be copied. This behavior
  and address allowlist/lockout upgrade effects are already documented in 2.56.0.
- Image alpha detection, crop window bounds and proportional resize behavior.
- Rendition profile forms, canonical paths, form ids and permission entry points.
- Migration additions use qualified table names and preserve existing defaults. No
  versioned migration or schema snapshot was modified by these fixes.

## Package provenance

[Hex release metadata](https://hex.pm/api/packages/phoenix_kit/releases/2.56.0) reports
publication at `2026-10-07T13:15:07.478188Z`, with no retirement when checked.
Downloaded [the published tarball](https://repo.hex.pm/tarballs/phoenix_kit-2.56.0.tar):
SHA-256 `7b73ba48d894c748cd25c3d7f49183fe0ccd1077d045632e35b4dcc59232c2a4`
matches the API checksum. All **809 regular packaged files** match `v2.56.0` byte for byte.

## Validation

- Full PostgreSQL-backed run of the fixes: **87 doctests, 8,751 tests, zero failures,
  six skipped, one excluded**, seed 683700; `PGDATABASE=phoenix_kit_test PGPOOL=10 mix test
  --max-cases 8`. The role lacks CREATEROLE, so that privilege-specific test was excluded.
- Final targeted regression and prefix migration run: **178 tests, zero failures**,
  including focal points, editing/reverting, crop hashes, real FFmpeg outputs, proxy
  rebinding, V210/V211 and the full migration chain into a named schema.
- `mix precommit`: passed, including warnings-as-errors compilation, unused-lock check,
  test compilation, formatting, strict Credo, Dialyzer and **291 JavaScript tests**.
- Real FFmpeg 7.0.2 smoke encodes: fixed box 120×90, fixed width/height 160×120,
  small input kept 320×240, shared quality 85, original-container preservation and JPEG
  poster all succeeded. Four permanent output tests were added; they skip explicitly when
  FFmpeg/ffprobe are missing. Image tests ran with ImageMagick 6 and Vix/libvips present.
- `mix deps.audit` and `mix hex.audit`: no vulnerabilities or retired/advisory packages.
- Vix-absent compilation/fallback probe: no compiler diagnostics; detection returns `:error`.

## Upgrade action

After deploying 2.56.1, use **Check files** on rendition profiles where subject crops were
used in 2.56.0. This recreates them with the corrected point-specific keys. Existing generated
videos are not automatically remade; rendition setting changes or a regeneration apply the
fixed video behavior. The address allowlist actions in 2.56.0's upgrade notes still apply.
