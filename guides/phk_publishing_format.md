# .phk (PhoenixKit) Publishing Format Guide

## Overview

The `.phk` format is PhoenixKit's component-based page markup language. It allows you to create pages with structured content that can be styled with different design variants **without changing the content**.

## File Location

Publishing entries are stored at:
```
priv/static/pages/<type>/<YYYY-MM-DD>/<HH:MM>/en.phk
```

Example:
```
priv/static/pages/blog/2025-10-28/14:30/en.phk
```

## Basic Structure

Every `.phk` file starts with a root `<Page>` element containing metadata:

```xml
<Page slug="home" title="Welcome" status="published" published_at="2025-10-28T14:00:00Z">
  <!-- Your content components go here -->
</Page>
```

### Page Attributes

- `slug` - URL-friendly identifier (e.g., "home", "about-us")
- `title` - Page title for SEO and display
- `status` - Publication status: `draft`, `published`, or `archived`
- `published_at` - ISO8601 timestamp (changes folder location when updated)
- `description` (optional) - Meta description for SEO

## Available Components

### Hero Component

The Hero section is typically the first visual element users see. It comes with **3 design variants** that can be switched without changing content.

#### Variant 1: Split Image (`variant="split-image"`)

**Best for:** Landing pages, product showcases, marketing pages

**Features:**
- Content on the left side
- Large image on the right side
- Gradient background (primary/secondary colors)
- Responsive grid layout

**Example:**
```xml
<Hero variant="split-image">
  <Headline>Build Your SaaS Faster</Headline>
  <Subheadline>Start shipping in days, not months</Subheadline>
  <CTA primary="true" action="/signup">Start Free Trial</CTA>
  <CTA action="#features">Learn More</CTA>
  <Image src="/assets/dashboard.png" alt="Dashboard Preview" />
</Hero>
```

**Result:**
- 2-column layout on desktop (content | image)
- Stacked layout on mobile
- Eye-catching gradient background
- Primary and secondary CTAs side-by-side

---

#### Variant 2: Centered (`variant="centered"`)

**Best for:** Welcome pages, announcements, simple messaging

**Features:**
- All content centered
- Neutral background
- Maximum width container (4xl)
- Generous spacing

**Example:**
```xml
<Hero variant="centered">
  <Headline>Welcome to PhoenixKit</Headline>
  <Subheadline>Everything you need to build modern web applications</Subheadline>
  <CTA primary="true" action="/get-started">Get Started</CTA>
  <CTA action="/docs">Read Documentation</CTA>
  <Image src="/assets/logo-large.png" alt="PhoenixKit Logo" />
</Hero>
```

**Result:**
- Single centered column
- Clean, professional look
- Works great with or without images
- Text-focused presentation

---

#### Variant 3: Minimal (`variant="minimal"`)

**Best for:** Documentation, blog posts, content pages

**Features:**
- Simple, distraction-free design
- Smaller padding
- Maximum width container (3xl)
- Text-only focused (images optional)

**Example:**
```xml
<Hero variant="minimal">
  <Headline>Getting Started Guide</Headline>
  <Subheadline>Learn how to build with PhoenixKit in 5 minutes</Subheadline>
  <CTA primary="true" action="#content">Start Reading</CTA>
</Hero>
```

**Result:**
- Compact, focused layout
- Quick to scan
- No distracting backgrounds
- Perfect for content consumption

---

### Child Components

These components work inside Hero (and other container components):

#### Headline
```xml
<Headline>Your Main Message Here</Headline>
```
- Renders as large, bold text (4xl to 6xl)
- Responsive sizing
- Base content color

#### Subheadline
```xml
<Subheadline>Supporting description or value proposition</Subheadline>
```
- Renders as medium text (lg to xl)
- Slightly muted color (70% opacity)
- Good for explanations

#### CTA (Call-to-Action)
```xml
<CTA primary="true" action="/signup">Button Text</CTA>
<CTA action="#section">Secondary Button</CTA>
```

**Attributes:**
- `primary` - Set to `"true"` for primary styling (default: `"false"`)
- `action` - URL or anchor link

**Styling:**
- Primary: Bold, colored button (btn-primary)
- Secondary: Outlined button (btn-outline)

#### Image
```xml
<Image src="/assets/hero-image.png" alt="Descriptive text" />
```

**Attributes:**
- `src` - Image path (relative or absolute)
- `alt` - Accessibility description

**Features:**
- Lazy loading enabled
- Rounded corners
- Drop shadow
- Responsive sizing

---

## Dynamic Data Placeholders

Use `{{variable}}` syntax to inject dynamic content:

```xml
<Headline>Welcome back, {{user.name}}</Headline>
<Subheadline>You have {{stats.active_projects}} active projects</Subheadline>
```

**Nested values** are supported:
- `{{user.name}}` → accesses `assigns.user.name`
- `{{stats.total_users}}` → accesses `assigns.stats.total_users`
- `{{framework}}` → accesses `assigns.framework`

**Preview mode** provides sample data:
```elixir
%{
  user: %{name: "Preview User", greeting_time: "Today"},
  stats: %{total_users: "1,000", active_projects: 5},
  framework: "Phoenix"
}
```

---

## Switching Design Variants

The power of `.phk` is that you can **change the entire design without touching content**. Just change the `variant` attribute:

**Before (Split Image):**
```xml
<Hero variant="split-image">
  <Headline>Build Your SaaS Faster</Headline>
  <Subheadline>Start shipping in days, not months</Subheadline>
  <CTA primary="true" action="/signup">Get Started</CTA>
</Hero>
```

**After (Centered) - Same content, different design:**
```xml
<Hero variant="centered">
  <Headline>Build Your SaaS Faster</Headline>
  <Subheadline>Start shipping in days, not months</Subheadline>
  <CTA primary="true" action="/signup">Get Started</CTA>
</Hero>
```

---

## Complete Example

See `priv/static/examples/sample_page.phk` for a complete example showing all three Hero variants in one file.

---

## How the Rendering Works

When a `.phk` file is rendered:

1. **Parse XML** → Convert to AST (Abstract Syntax Tree)
2. **Inject Data** → Replace `{{placeholders}}` with actual values
3. **Resolve Components** → Map `<Hero>` → `PhoenixKitWeb.Components.Publishing.Hero`
4. **Apply Variant** → Select the correct rendering function based on `variant` attribute
5. **Render HTML** → Generate final HTML output

---

## Adding New Components (Future)

The system is designed to be extensible. Future components might include:

```xml
<!-- Features Section -->
<Features variant="grid">
  <Feature icon="rocket">
    <Title>Fast Development</Title>
    <Description>Ship features quickly</Description>
  </Feature>
</Features>

<!-- Testimonials -->
<Testimonials variant="carousel">
  <Testimonial author="Jane Doe" role="CTO" company="TechCorp">
    This saved us months of development time.
  </Testimonial>
</Testimonials>

<!-- CTA Section -->
<CTASection variant="centered-form">
  <Headline>Ready to get started?</Headline>
  <EmailCapture button-text="Get Early Access" />
</CTASection>
```

Each component would have its own `.ex` file with multiple variant implementations.

---

## Best Practices

### Content Organization
- ✅ Use semantic component names (`<Hero>`, not `<Section1>`)
- ✅ Keep content and structure separate from design decisions
- ✅ Use descriptive alt text for images
- ✅ Choose variants based on page purpose, not content

### Dynamic Data
- ✅ Use placeholders for user-specific content (`{{user.name}}`)
- ✅ Use placeholders for stats that change (`{{stats.count}}`)
- ❌ Don't use placeholders for static marketing copy

### Variant Selection
- `split-image` → Marketing pages, product showcases, conversions
- `centered` → Welcome pages, announcements, feature launches
- `minimal` → Documentation, blog posts, content-heavy pages

### Accessibility
- ✅ Always provide meaningful `alt` text for images
- ✅ Use descriptive CTA button text ("Start Free Trial" not "Click Here")
- ✅ Structure content logically (Headline → Subheadline → CTA)

---

## Troubleshooting

### "Failed to render preview"
- Check XML syntax (all tags must be closed: `<Hero>...</Hero>`)
- Ensure `variant` attribute is valid (`split-image`, `centered`, or `minimal`)
- Verify all attributes are quoted: `primary="true"` not `primary=true`

### Dynamic placeholders not working
- Check placeholder syntax: `{{user.name}}` not `{user.name}`
- Ensure the variable exists in preview assigns
- Nested paths must match exactly (case-sensitive)

### Content not displaying
- Verify you're using child components inside `<Hero>` (not plain text)
- Check that `<Page>` is the root element
- Ensure all opening tags have matching closing tags

---

## Reference: Hero Variants Comparison

| Variant | Layout | Background | Best For | Image Required |
|---------|--------|------------|----------|----------------|
| `split-image` | 2-column (content \| image) | Gradient (primary/secondary) | Landing pages, marketing | Recommended |
| `centered` | Single column, centered | Neutral (base-200) | Announcements, welcome | Optional |
| `minimal` | Single column, centered | None | Documentation, content | Optional |

---

Built with ❤️ for PhoenixKit
