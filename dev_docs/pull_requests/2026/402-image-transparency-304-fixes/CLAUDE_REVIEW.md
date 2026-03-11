# PR #402 Review — Fix Image Transparency, 304 Support, Newsletter Delivery

**Author:** Tymofii Shapovalov (`timujinne`)
**Merged:** 2026-03-11
**Files changed:** 13 (99 additions, 31 deletions)

## Summary

Bug fix PR addressing issues from PR #400 review plus two independent fixes:
1. **WebP transparency** — detect alpha channel before center-crop, use `none` background, override jpg→webp when alpha present.
2. **304 Not Modified** — proper ETag/If-None-Match support in `FileController`.
3. **Newsletter fixes** — all critical bugs from PR #400 review (JSONB field access, SES message ID, Earmark error handling, endpoint hardcoding, etc.)

## What's Good

- **Addresses all critical review items** from PR #400 — JSONB crashes fixed, SES message_id captured, merge conflict marker removed, version bumped, error flash persistence.
- **`has_alpha_channel?/1`** — clean approach using ImageMagick `identify -format "%[channels]"` with proper error handling via rescue.
- **304 support** — simple and correct ETag comparison via `Plug.Conn.get_req_header/2`.
- **`clone_template` fix** — now copies all locale translations with "(Copy)" suffix, not just "en". Clean `Map.new/2` usage.
- **Template search** — `fragment("?::text", t.display_name)` searches across all locales instead of just "en".

## Issues

### 1. `has_alpha_channel?` string check is too broad (Medium)

**File:** `lib/modules/storage/services/image_processor.ex`

```elixir
defp has_alpha_channel?(file_path) do
  case System.cmd("identify", ["-format", "%[channels]", file_path], ...) do
    {output, 0} -> String.contains?(String.trim(output), "a")
    _ -> false
  end
end
```

`String.contains?(output, "a")` will match any channel string containing "a" — including `"gra"` (grayscale) or `"cmyka"`. In practice, ImageMagick returns `"srgba"` for RGBA and `"srgb"` for no alpha, so this works for the common case. But a safer check would be `String.ends_with?(output, "a")` or explicitly checking for `"srgba"` / `"graya"`.

### 2. 304 response should not include `Content-Type` or `Content-Disposition` (Low)

**File:** `lib/phoenix_kit_web/controllers/file_controller.ex`

The 304 branch correctly omits content headers, which is good. However, RFC 7232 recommends including `Content-Type` in 304 responses for cache validators. This is a minor spec compliance point — browsers handle it either way.

### 3. `Earmark.as_html` error branch returns partial HTML (Low)

**File:** `lib/modules/newsletters/broadcaster.ex`

```elixir
case Earmark.as_html(broadcast.markdown_body || "") do
  {:ok, html, _warnings} -> html
  {:error, html, _errors} -> html
end
```

Earmark's `{:error, html, errors}` tuple still contains partially rendered HTML. Using it silently may send malformed content. Consider logging the errors at `:warning` level so they're visible.

### 4. `Map.get(result, :id)` assumes Swoosh result structure (Low)

**File:** `lib/modules/newsletters/workers/delivery_worker.ex:44`

```elixir
{:ok, result} <- send_email(...)
message_id = Map.get(result, :id)
```

The shape of `result` from `PhoenixKit.Mailer.deliver_email()` depends on the Swoosh adapter. SES returns `%{id: "..."}` but other adapters may return different structures. `Map.get(result, :id)` safely returns `nil` for non-SES adapters, so this isn't a crash — but the `message_id` will be `nil` for local dev (Swoosh.Adapters.Local). Worth a comment noting this is SES-specific.

### 5. Missing CHANGELOG entry (Nitpick)

The PR removes the conflict marker from CHANGELOG but doesn't add its own entry for the transparency fix, 304 support, or newsletter fixes.

## Verdict

Clean bug fix PR. Addresses all critical items from the PR #400 review promptly. The alpha channel detection (#1) could be tightened but works in practice. No new bugs introduced.
