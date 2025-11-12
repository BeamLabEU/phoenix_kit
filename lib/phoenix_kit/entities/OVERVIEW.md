# PhoenixKit Entities System

PhoenixKit’s Entities layer is a WordPress ACF–style content engine. It lets administrators define custom content types at runtime, attach structured fields, and manage records without writing migrations or shipping new code. This README gives a full overview so a developer (or AI teammate) can understand what exists, how it fits together, and how to extend it safely.

---

## High-level capabilities

- **Entity blueprints** – Define reusable content types (`phoenix_kit_entities`) with metadata, singular/plural labels, icon, status, JSON field schema, and optional custom settings.
- **Dynamic fields** – 13+ built-in field types (text, textarea, number, boolean, date, email, URL, select, radio, checkbox, rich text, file, image, relation). Field definitions live in JSONB and are validated at creation time.
- **Entity data records** – Store instances of an entity (`phoenix_kit_entity_data`) with slug support, status workflow (draft/published/archived), JSONB data payload, metadata, creator tracking, and timestamps.
- **Admin UI** – LiveView dashboards for managing blueprints, browsing/creating data, filtering, and adjusting module settings.
- **Settings + security** – Feature toggle, max entities per user, relation/file flags, auto slugging, etc., persisted in `phoenix_kit_settings`. All surfaces are gated behind the admin scope.
- **Statistics** – Counts and summaries for dashboards and monitoring.

---

## Folder structure

```
lib/phoenix_kit/
└── entities/
    ├── entities.ex          # Entity schema + business logic
    ├── entity_data.ex       # Data record schema + CRUD helpers
    ├── field_types.ex       # Registry of supported field types
    └── form_builder.ex      # Dynamic form rendering + validation helpers

lib/phoenix_kit_web/live/modules/entities/
├── entities.ex / .html.heex         # Entity dashboard
├── entity_form.ex / .html.heex      # Create/update entity definitions
├── data_navigator.ex / .html.heex   # Browse/filter records per entity
├── data_form.ex / .html.heex        # Create/update individual records
└── entities_settings.ex / .html.heex# System configuration

lib/phoenix_kit/entities/
├── OVERVIEW.md                     # High-level guide (this file)
└── DEEP_DIVE.md                    # Architectural deep dive

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
- CRUD helpers (`list_entities/0`, `get_entity!/1`, `get_entity_by_name/1`, `create_entity/1`, `update_entity/2`, `delete_entity/1`).
- Statistics (`get_system_stats/0`, `count_entities/0`, `count_user_entities/1`).
- Settings helpers (`enabled?/0`, `enable_system/0`, `disable_system/0`, `get_config/0`).
- Limit enforcement (`validate_user_entity_limit/1`).

Field validation pipeline ensures every entry in `fields_definition` has `type/key/label`, uses a supported type, and merges defaults as needed.

### `PhoenixKit.Entities.EntityData`
Manages actual records:
- Schema + changeset verifying required fields, slug format, status, and cross-checking submitted JSON against the entity definition.
- CRUD and query helpers (`list_all/0`, `list_by_entity/1`, `search_by_title/2`, `create/1`, `update/2`, etc.).
- Field-level validation ensures required fields are present, numbers are numeric, booleans are booleans, options exist, etc.

### `PhoenixKit.Entities.FieldTypes`
Registry of supported field types with metadata:
- `all/0`, `list_types/0`, `for_picker/0` – introspection for UI builders.
- Category helpers, default properties, and `validate_field/1` to ensure field definitions are complete.
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
- **Media**: `image`, `file`
- **Relations**: `relation`

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

| Setting | Description | Exposed via |
|---------|-------------|-------------|
| `entities_enabled` | Master on/off switch for the module | `/admin/modules`, `Entities.enable_system/0` |
| `entities_max_per_user` | Blueprint limit per creator | `Entities_settings` UI & `Entities.get_max_per_user/0` |
| `entities_allow_relations` | Enables relation field type | Settings UI |
| `entities_file_upload` | Enables file/image field types | Settings UI |
| `entities_auto_generate_slugs` | (Optional) controls slug generation in forms | Settings UI |
| `entities_default_status` | Default status for new records | Settings UI |

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
{:ok, blog_entity} =
  PhoenixKit.Entities.create_entity(%{
    name: "blog_post",
    display_name: "Blog Post",
    display_name_plural: "Blog Posts",
    icon: "hero-document-text",
    created_by: admin.id,
    fields_definition: [
      %{"type" => "text", "key" => "title", "label" => "Title", "required" => true},
      %{"type" => "rich_text", "key" => "content", "label" => "Content"}
    ]
  })
```

### Creating a record
```elixir
{:ok, _record} =
  PhoenixKit.Entities.EntityData.create(%{
    entity_id: blog_entity.id,
    title: "My First Post",
    status: "published",
    created_by: admin.id,
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

## Related documentation

- `ENTITIES_SYSTEM.md` – long-form analysis, rationale, and implementation notes
- `lib/phoenix_kit/migrations/postgres/v17.ex` – database migration
- `lib/phoenix_kit/utils/routes.ex` – locale-aware path helpers
- `lib/phoenix_kit_web/components/layout_wrapper.ex` – navigation wrapper that consumes the assigns set by these LiveViews

---

With this overview you should have everything needed to work on the Entities system—whether that’s building new UI affordances, adding field types, or integrating entities into other PhoenixKit features. For deeper rationale and implementation notes, open `DEEP_DIVE.md` in the same directory.
