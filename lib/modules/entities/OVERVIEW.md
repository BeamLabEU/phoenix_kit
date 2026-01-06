# PhoenixKit Entities System

PhoenixKit’s Entities layer is a WordPress ACF–style content engine. It lets administrators define custom content types at runtime, attach structured fields, and manage records without writing migrations or shipping new code. This README gives a full overview so a developer (or AI teammate) can understand what exists, how it fits together, and how to extend it safely.

---

## High-level capabilities

- **Entity blueprints** – Define reusable content types (`phoenix_kit_entities`) with metadata, singular/plural labels, icon, status, JSON field schema, and optional custom settings.
- **Dynamic fields** – 11 built-in field types (text, textarea, number, boolean, date, email, URL, select, radio, checkbox, rich text). Field definitions live in JSONB and are validated at creation time. *(Note: image, file, and relation fields are defined but not yet fully implemented—UI shows "coming soon" placeholders.)*
- **Entity data records** – Store instances of an entity (`phoenix_kit_entity_data`) with slug support, status workflow (draft/published/archived), JSONB data payload, metadata, creator tracking, and timestamps.
- **Admin UI** – LiveView dashboards for managing blueprints, browsing/creating data, filtering, and adjusting module settings.
- **Settings + security** – Feature toggle and max entities per user are enforced; additional settings (relation/file flags, auto slugging, etc.) are persisted in `phoenix_kit_settings` but reserved for future use. All surfaces are gated behind the admin scope.
- **Statistics** – Counts and summaries for dashboards and monitoring.
- **Public Form Builder** – Create embeddable forms for public-facing pages with security features (honeypot, time-based validation, rate limiting), configurable actions, and submission statistics.

---

## Folder structure

```
lib/modules/entities/
├── entities.ex          # Entity schema + business logic
├── entity_data.ex       # Data record schema + CRUD helpers
├── field_types.ex       # Registry of supported field types
├── form_builder.ex      # Dynamic form rendering + validation helpers
├── html_sanitizer.ex    # XSS prevention for rich_text fields
├── presence.ex          # Phoenix.Presence for real-time collaboration
├── presence_helpers.ex  # FIFO locking and presence utilities
├── events.ex            # PubSub event broadcasting
├── OVERVIEW.md          # High-level guide (this file)
├── DEEP_DIVE.md         # Architectural deep dive
├── mirror/              # Entity definition/data mirroring to filesystem
│   ├── exporter.ex
│   ├── importer.ex
│   └── storage.ex
└── web/
    ├── entities.ex / .html.heex         # Entity dashboard
    ├── entity_form.ex / .html.heex      # Create/update entity definitions + public form config
    ├── data_navigator.ex / .html.heex   # Browse/filter records per entity
    ├── data_form.ex / .html.heex        # Create/update individual records
    ├── data_view.ex                     # Read-only view component
    ├── entities_settings.ex / .html.heex# System configuration
    └── hooks.ex                         # LiveView hooks for entity pages

lib/phoenix_kit_web/controllers/
└── entity_form_controller.ex        # Public form submission handler

lib/phoenix_kit_web/components/blogging/
└── entity_form.ex                   # Embeddable public form component

lib/phoenix_kit/migrations/postgres/
└── v17.ex                           # Creates entities + entity_data tables, seeds settings
```

---

## Database schema (migration V17)

### `phoenix_kit_entities`
- `id` – primary key
- `name` – unique slug (snake_case)
- `display_name` – singular UI label
- `display_name_plural` – plural label (for menus/navigation)
- `description` – optional help text
- `icon` – hero icon identifier
- `status` – `draft | published | archived`
- `fields_definition` – JSONB array describing fields
- `settings` – optional JSONB for entity-specific config
- `created_by` – admin user id
- `date_created`, `date_updated` – UTC timestamps

Indexes cover `name`, `status`, `created_by`. A comment block documents JSON columns.

### `phoenix_kit_entity_data`
- `id` – primary key
- `entity_id` – foreign key → `phoenix_kit_entities`
- `title` – record label
- `slug` – optional unique slug per entity
- `status` – `draft | published | archived`
- `data` – JSONB map keyed by field definition
- `metadata` – optional JSONB extras
- `created_by` – admin user id
- `date_created`, `date_updated`

Indexes cover `entity_id`, `slug`, `status`, `created_by`, `title`. FK cascades on delete.

### Seeded settings
- `entities_enabled` – boolean toggle (default `false`)
- `entities_max_per_user` – integer limit (default `100`)
- `entities_allow_relations` – boolean (default `true`)
- `entities_file_upload` – boolean (default `false`)

---

## Core modules

### `PhoenixKit.Entities`
Responsible for entity blueprints:
- Schema + changeset enforcing unique names, valid field definitions, timestamps, etc.
- CRUD helpers (`list_entities/0`, `get_entity!/1`, `get_entity/1`, `get_entity_by_name/1`, `create_entity/1`, `update_entity/2`, `delete_entity/1`, `change_entity/2`).
- Statistics (`get_system_stats/0`, `count_entities/0`, `count_user_entities/1`).
- Settings helpers (`enabled?/0`, `enable_system/0`, `disable_system/0`, `get_config/0`).
- Limit enforcement (`validate_user_entity_limit/1`).

Note: `create_entity/1` auto-fills `created_by` with the first admin user if not provided.

Field validation pipeline ensures every entry in `fields_definition` has `type/key/label` and uses a supported type. Note: the changeset validates but does not enrich field definitions—use `FieldTypes.new_field/4` to apply default properties.

### `PhoenixKit.Entities.EntityData`
Manages actual records:
- Schema + changeset verifying required fields, slug format, status, and cross-checking submitted JSON against the entity definition.
- CRUD and query helpers (`list_all/0`, `list_by_entity/1`, `get!/1`, `get/1`, `search_by_title/2`, `create/1`, `update/2`, `delete/1`, `change/2`).
- Field-level validation ensures required fields are present, numbers are numeric, booleans are booleans, options exist, etc.

Note: `create/1` auto-fills `created_by` with the first admin user if not provided.

### `PhoenixKit.Entities.FieldTypes`
Registry of supported field types with metadata:
- `all/0`, `list_types/0`, `for_picker/0` – introspection for UI builders.
- Category helpers, default properties, and `validate_field/1` to ensure field definitions are complete.
- Field builder helpers for programmatic creation:
  - `new_field/4` – Create any field type with options
  - `select_field/4`, `radio_field/4`, `checkbox_field/4` – Choice fields with options list
  - `text_field/3`, `textarea_field/3`, `email_field/3`, `number_field/3`, `boolean_field/3`, `rich_text_field/3` – Common field types
- Used both when saving entity definitions and when rendering forms.

### `PhoenixKit.Entities.FormBuilder`
- Renders form inputs dynamically based on field definitions (`build_fields/3`, `build_field/3`).
- Provides `validate_data/2` and lower-level helpers to check payloads before they reach `EntityData.changeset/2`.
- Produces consistent labels, placeholders, and helper text aligned with Tailwind/daisyUI styling.

---

## LiveView surfaces

| Route | LiveView | Purpose |
|-------|----------|---------|
| `/admin/entities` | `entities.ex` | Dashboard listing entity blueprints, stats, actions |
| `/admin/entities/new` / `/:id/edit` | `entity_form.ex` | Create/update entity definitions |
| `/admin/entities/:slug/data` | `data_navigator.ex` | Table & card views of records, search, status filters |
| `/admin/entities/:slug/data/new` / `/:id/edit` | `data_form.ex` | Create/update individual records |
| `/admin/settings/entities` | `entities_settings.ex` | Toggle module, configure behaviour |

LiveViews share a layout wrapper that expects these assigns:
- `@current_locale` – required for locale-aware paths
- `@current_path` – for sidebar highlighting
- `@project_title` – used in layout/head

All navigation helpers use `Routes.locale_aware_path/2` (or `PhoenixKit.Utils.Routes.path/2`) so URLs keep the active locale prefix (e.g., `/phoenix_kit/ru/admin/entities`).

---

## Field types at a glance

- **Basic**: `text`, `textarea`, `rich_text`, `email`, `url`
- **Numeric**: `number`
- **Boolean**: `boolean`
- **Date/Time**: `date`
- **Choice**: `select`, `radio`, `checkbox`
- **Media** *(coming soon)*: `image`, `file` – defined in schema but renders placeholder UI
- **Relations** *(coming soon)*: `relation` – defined in schema but not yet functional

Each field definition is a map like:
```elixir
%{
  "type" => "select",
  "key" => "category",
  "label" => "Category",
  "required" => true,
  "options" => ["Tech", "Business", "Lifestyle"],
  "validation" => %{}
}
```

`FormBuilder` merges default props (placeholder, rows, etc.) and renders the correct component. Validation ensures options exist when required and types match.

---

## Settings & configuration

| Setting | Description | Exposed via | Status |
|---------|-------------|-------------|--------|
| `entities_enabled` | Master on/off switch for the module | `/admin/modules`, `Entities.enable_system/0` | ✅ Active |
| `entities_max_per_user` | Blueprint limit per creator | Settings UI & `Entities.get_max_per_user/0` | ✅ Active |
| `entities_allow_relations` | Reserved for future relation field toggle | Settings UI | 🚧 Not yet enforced |
| `entities_file_upload` | Reserved for future file/image upload toggle | Settings UI | 🚧 Not yet enforced |
| `entities_auto_generate_slugs` | Reserved for optional slug generation control | Settings UI | 🚧 Not yet enforced (slugs always auto-generate) |
| `entities_default_status` | Reserved for default status on new records | Settings UI | 🚧 Not yet enforced (defaults to "published") |
| `entities_require_approval` | Reserved for approval workflow | Settings UI | 🚧 Not yet enforced |
| `entities_data_retention_days` | Reserved for data retention policy | Settings UI | 🚧 Not yet enforced |
| `entities_enable_revisions` | Reserved for revision history | Settings UI | 🚧 Not yet enforced |
| `entities_enable_comments` | Reserved for commenting system | Settings UI | 🚧 Not yet enforced |

> **Note**: Settings marked "Not yet enforced" are persisted in the database and visible in the admin UI, but the underlying functionality is not yet implemented. They are placeholders for future features.

`PhoenixKit.Entities.get_config/0` returns a map:
```elixir
%{
  enabled: boolean,
  max_per_user: integer,
  allow_relations: boolean,
  file_upload: boolean,
  entity_count: integer,
  total_data_count: integer
}
```

---

## Common workflows

### Enabling the module
```elixir
{:ok, _setting} = PhoenixKit.Entities.enable_system()
PhoenixKit.Entities.enabled?()
# => true/false
```

### Creating an entity blueprint
```elixir
# Note: created_by is optional - auto-fills with first admin user if omitted
{:ok, blog_entity} =
  PhoenixKit.Entities.create_entity(%{
    name: "blog_post",
    display_name: "Blog Post",
    display_name_plural: "Blog Posts",
    icon: "hero-document-text",
    # created_by: admin.id,  # Optional!
    fields_definition: [
      %{"type" => "text", "key" => "title", "label" => "Title", "required" => true},
      %{"type" => "rich_text", "key" => "content", "label" => "Content"}
    ]
  })
```

### Creating fields with builder helpers
```elixir
alias PhoenixKit.Entities.FieldTypes

# Build fields programmatically
fields = [
  FieldTypes.text_field("title", "Title", required: true),
  FieldTypes.textarea_field("excerpt", "Excerpt"),
  FieldTypes.select_field("category", "Category", ["Tech", "Business", "Lifestyle"]),
  FieldTypes.checkbox_field("tags", "Tags", ["Featured", "Popular", "New"]),
  FieldTypes.boolean_field("featured", "Featured Post", default: false)
]

{:ok, entity} = PhoenixKit.Entities.create_entity(%{
  name: "article",
  display_name: "Article",
  fields_definition: fields
})
```

### Creating a record
```elixir
# Note: created_by is optional - auto-fills with first admin user if omitted
{:ok, _record} =
  PhoenixKit.Entities.EntityData.create(%{
    entity_id: blog_entity.id,
    title: "My First Post",
    status: "published",
    # created_by: admin.id,  # Optional!
    data: %{"title" => "My First Post", "content" => "<p>Hello</p>"}
  })
```

### Counting statistics
```elixir
PhoenixKit.Entities.get_system_stats()
# => %{total_entities: 5, active_entities: 4, total_data_records: 23}
```

### Enforcing limits
```elixir
PhoenixKit.Entities.validate_user_entity_limit(admin.id)
# {:ok, :valid} or {:error, "You have reached the maximum limit of 100 entities"}
```

---

## Extending the system

1. **New field type** – update `FieldTypes` (definition + defaults), extend `FormBuilder`, and add validation handling to `EntityData` if needed.
2. **New settings** – add to `phoenix_kit_settings` (migration + defaults), expose in the settings LiveView, and document in `get_config/0`.
3. **API surface** – add helper functions in `Entities` or `EntityData` if they’re reused across LiveViews or future REST/GraphQL endpoints.
4. **LiveView changes** – keep locale and nav rules in mind, reuse existing slots/components for consistency, and add tests where possible.

---

## Public Form Builder

The Entities system includes a public form builder for creating embeddable forms on public-facing pages.

### Features

- **Embeddable Component**: Use `<EntityForm entity_slug="contact" />` in blogging pages
- **Field Selection**: Choose which entity fields appear on the public form
- **Security Options**: Honeypot, time-based validation (3s minimum), rate limiting (5/min)
- **Configurable Actions**: reject_silent, reject_error, save_suspicious, save_log
- **Statistics**: Track submissions, rejections, and security triggers
- **Debug Mode**: Detailed error messages for troubleshooting
- **Metadata Collection**: IP address, browser, device, referrer, timing data
- **HTML Sanitization**: Rich text fields automatically sanitized to prevent XSS

### Configuration (entity settings)

| Setting | Description |
|---------|-------------|
| `public_form_enabled` | Master toggle |
| `public_form_fields` | List of field keys to include |
| `public_form_title` | Form title |
| `public_form_description` | Form description |
| `public_form_submit_text` | Submit button text |
| `public_form_success_message` | Success message |
| `public_form_honeypot` | Enable honeypot protection |
| `public_form_time_check` | Enable time-based validation |
| `public_form_rate_limit` | Enable rate limiting |
| `public_form_debug_mode` | Show detailed error messages |
| `public_form_collect_metadata` | Collect submission metadata |

### Embedding in pages

```heex
<EntityForm entity_slug="contact" />
```

The component checks if the form is enabled AND has fields selected before rendering. Submissions go to `/phoenix_kit/entities/{slug}/submit`.

### Real-Time Collaboration

The entity form editor supports real-time collaboration with FIFO locking:
- First user becomes the lock owner (can edit)
- Subsequent users become spectators (read-only)
- Live updates broadcast to all viewers
- Automatic promotion when owner leaves

---

## Related documentation

- `DEEP_DIVE.md` – long-form analysis, rationale, and implementation notes (in this directory)
- `lib/phoenix_kit/migrations/postgres/v17.ex` – database migration
- `lib/phoenix_kit/utils/routes.ex` – locale-aware path helpers
- `lib/phoenix_kit_web/components/layout_wrapper.ex` – navigation wrapper that consumes the assigns set by these LiveViews

---

With this overview you should have everything needed to work on the Entities system—whether that’s building new UI affordances, adding field types, or integrating entities into other PhoenixKit features. For deeper rationale and implementation notes, open `DEEP_DIVE.md` in the same directory.
