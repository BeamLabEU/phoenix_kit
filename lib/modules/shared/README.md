# Shared Module

Cross-module reusable components extracted from the Publishing module. These components provide common UI patterns used across multiple PhoenixKit modules (Publishing, Entities, etc.).

## Components

All components live in `lib/modules/shared/components/`:

| Component | Description |
|-----------|-------------|
| `page.ex` | Full-width page layout wrapper |
| `hero.ex` | Hero section with background image/video support |
| `headline.ex` | Styled headline text block |
| `subheadline.ex` | Secondary headline / tagline |
| `cta.ex` | Call-to-action button/link |
| `image.ex` | Responsive image with Storage integration |
| `video.ex` | Video embed (YouTube, Vimeo, direct) |
| `entity_form.ex` | Reusable entity editing form fields |

## Usage

Components are imported via the Shared module and available in templates that use PhoenixKit's component system.

```elixir
import PhoenixKit.Modules.Shared.Components.Hero
import PhoenixKit.Modules.Shared.Components.Headline
```

## Architecture

These components were extracted from Publishing to avoid circular dependencies when multiple modules need the same UI primitives. The Shared module has no database tables or business logic -- it is purely a component library.
