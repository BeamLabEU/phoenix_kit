# .phk Blogging Format (Current Implementation)

PhoenixKit’s blogging module stores every post as a `.phk` file. Each file is a **YAML frontmatter block** followed by regular **Markdown**. Authors can sprinkle inline PHK components (for example `<Image … />`) anywhere inside the Markdown, but there is no longer a root `<Post>` wrapper or XML layout.

---

## Where posts live

Posts are kept under `priv/blogging/<blog>/…` inside your host application. The folder layout depends on the blog’s storage mode:

| Blog mode | Path template | Example |
|-----------|---------------|---------|
| Timestamp (legacy/default) | `priv/blogging/<blog>/<YYYY-MM-DD>/<HH:MM>/<language>.phk` | `priv/blogging/news/2025-01-15/09:30/en.phk` |
| Slug (new) | `priv/blogging/<blog>/<post-slug>/<language>.phk` | `priv/blogging/docs/getting-started/en.phk` |

Each language/localisation of a post gets its own `.phk` file in the same directory.

---

## File anatomy

```yaml
---
slug: simple-version-original-size
title: Simple Version (Original Size)
status: draft            # draft | published | archived
published_at: 2025-11-07T22:42:00Z
created_at: 2025-11-07T22:42:17.231679Z
created_by_email: max@don.ee
updated_by_email: max@don.ee
---

# Heading 1

Standard **Markdown** lives here. Use `##` for subheadings, `-` for bullet lists, code fences, etc.

Inline PHK components can appear anywhere in the Markdown body:

<Image file_id="019a6f96-e895-74e2-a745-1b596ee235af" file_variant="medium" alt="Screenshot" />

Continue writing Markdown below the component.
```

### Frontmatter keys

Only a subset is required, but the blogging UI will populate everything shown above. Notable keys:

- `slug` – used for slug-mode directories and public URLs.
- `title` – displayed in admin tables and public templates.
- `status` – controls whether the post is discoverable publicly (`published` only).
- `published_at` – timestamp used for ordering and for timestamp-mode folders.
- `featured_image_id` – optional PhoenixKit Storage file ID used for the public listing thumbnail.
- `created_by_* / updated_by_*` – audit metadata; the editor manages these.

---

## Markdown + inline PHK components

After the frontmatter, everything is standard Markdown. The renderer automatically:

1. Runs Markdown through Earmark (GitHub-flavoured Markdown).
2. Scans for inline PHK components (`<Image />`, `<Hero>…</Hero>`, `<CTA />`, `<Headline>`, `<Subheadline>`).
3. Renders those components with Phoenix components before returning HTML.

This means you can drop components alongside text:

```markdown
You can mix **bold text** and inline components:

<CTA primary="true" action="/signup">Start Free Trial</CTA>

- Bullet one
- Bullet two
```

### Supported inline components

| Component | Notes |
|-----------|-------|
| `<Image … />` | Works with either `src="/path/to/file.jpg"` or `file_id="…"`. Optional `file_variant="thumbnail" | "small" | "medium" | "large"` picks a specific variant from PhoenixKit Storage. The renderer now always returns the natural dimensions; add your own `class` if you want to constrain width. |
| `<Hero variant="split-image|centered|minimal"> … </Hero>` | A layout block that can wrap `<Headline>`, `<Subheadline>`, `<CTA />`, `<Image />`. Use sparingly inside Markdown (usually near the top). |
| `<Headline>…</Headline>` | Renders a hero-style heading. |
| `<Subheadline>…</Subheadline>` | Medium-sized supporting text. |
| `<CTA primary="true|false" action="/path-or-anchor">Label</CTA>` | Button styled by the admin theme. |
| `<Video …>Caption</Video>` | Responsive YouTube embeds. Provide either `video_id="dQw4w9WgXcQ"` or a `url="https://youtu.be/dQw4w9WgXcQ"`. Optional attributes: `autoplay`, `muted`, `controls`, `loop`, `start` (seconds), and `ratio` (`16:9`, `4:3`, `1:1`, `21:9`). Use the component body (or `caption="..."` when self-closing) to show a caption. |

Additional components can be introduced by adding Phoenix components under `lib/phoenix_kit_web/components/blogging/` and registering them in the PageBuilder renderer.

---

## Storage integration & variants

When an `<Image>` references `file_id="…"`, the renderer calls `PhoenixKit.Storage.get_public_url_by_id/2`. The storage layer:

1. Looks for a matching file + variant (`original`, `thumbnail`, `small`, `medium`, `large`, etc.).
2. Returns the provider’s public URL if available (S3, R2, CDN…).
3. Falls back to PhoenixKit’s signed `/phoenix_kit/file/:id/:variant/:token` route for local/dev setups.

If a variant does not exist yet (for example someone references `medium` before the variant generator runs), the renderer falls back to `original`. The `<Image>` component now *always* renders the file at its natural size; supply your own classes (e.g. `class="w-full"`) if you need to stretch or constraint it.

---

## Complete example

```yaml
---
slug: product-updates-oct-2025
title: Product Updates – October 2025
status: published
published_at: 2025-10-31T09:00:00Z
---

# October Highlights

Thanks for building with PhoenixKit! Here are the highlights from this month.

<Hero variant="split-image">
  <Headline>Maintenance Mode v2</Headline>
  <Subheadline>Plan downtime with confidence.</Subheadline>
  <CTA primary="true" action="/admin/modules">Enable Module</CTA>
  <Image file_id="018e3c4a-9f6b-7890-abcd-ef1234567890" alt="Maintenance Mode Screenshot" />
</Hero>

## New referral analytics

- Multi-touch attribution
- CSV exports
- Improved fraud detection

<Image
  file_id="019a6f96-e895-74e2-a745-1b596ee235af"
  file_variant="thumbnail"
  class="w-full"
  alt="Referral dashboard"
/>
```

---

## Reference example – storage-focused post

```yaml
---
slug: storage-integration-example
title: Storage Integration Example
status: draft
published_at: 2025-07-01T10:00:00Z
---

# Working with PhoenixKit Storage

<!-- Example 1: Using direct URL -->
<Hero variant="split-image">
  <Headline>Direct URL Image Example</Headline>
  <Subheadline>This uses a direct asset path to display an image.</Subheadline>
  <CTA primary="true" action="/signup">Get Started</CTA>
  <Image src="/assets/dashboard-preview.png" alt="Dashboard Preview" />
</Hero>

<!-- Example 2: Using file_id -->
<Hero variant="centered">
  <Headline>Storage File ID Example</Headline>
  <Subheadline>This pulls from PhoenixKit Storage.</Subheadline>
  <CTA primary="true" action="/upload">Upload Image</CTA>
  <Image file_id="018e3c4a-9f6b-7890-abcd-ef1234567890" alt="Uploaded Image" />
</Hero>

<!-- Example 3: Using file_id with variant -->
<Hero variant="minimal">
  <Headline>Thumbnail Variant</Headline>
  <Subheadline>Great for small inline previews.</Subheadline>
  <Image
    file_id="018e3c4a-9f6b-7890-abcd-ef1234567890"
    file_variant="thumbnail"
    alt="Thumbnail Image"
  />
</Hero>

<!-- Example 4: Custom classes -->
<Hero variant="split-image">
  <Headline>Custom Styling</Headline>
  <Subheadline>Combine variants with Tailwind utility classes.</Subheadline>
  <Image
    file_id="018e3c4a-9f6b-7890-abcd-ef1234567890"
    file_variant="medium"
    class="border-4 border-primary"
    alt="Styled Image"
  />
</Hero>
```

---

## Example – embedding a YouTube video

```markdown
## Watch the launch recap

<Video
  url="https://youtu.be/dQw4w9WgXcQ"
  autoplay="false"
  muted="false"
  ratio="16:9"
  start="42"
>
  Highlights from our community livestream.
</Video>
```

---

## Rendering pipeline (current behaviour)

1. **Frontmatter parsing** – YAML is parsed to capture metadata.
2. **Markdown rendering** – Earmark converts the Markdown body to HTML.
3. **Component pass** – the renderer finds inline PHK component tags and swaps them with Phoenix component output.
4. **Storage resolution** – `<Image>` elements fetch URLs from `PhoenixKit.Storage`; caching and signed URLs ensure files are served even when only local storage exists.
5. **Output** – the resulting HTML is cached for published posts to speed up public requests.

There is no longer a pure-XML PageBuilder flow; Markdown is the primary content format. The legacy component pipeline still powers inline components, which is why the supporting modules remain in the codebase.

---

## Best practices

- **Let Markdown do the heavy lifting.** Use inline components only when you need structured UI blocks.
- **Always set `alt` text** for `<Image>` components.
- **Reference the correct blog mode path.** If you switch a blog from timestamp to slug mode (or vice versa), migrate the files accordingly.
- **Check variants in Storage.** If you expect `thumbnail` files, verify that automatic variant generation is enabled in Settings → Storage.
- **Keep frontmatter clean.** Avoid adding arbitrary keys unless the blogging UI or your host app actually reads them.
- **Preview before publishing.** The admin preview now uses the same renderer as the public site, so what you see there should match production output.

---

Built with ❤️ for PhoenixKit (updated early 2025)
