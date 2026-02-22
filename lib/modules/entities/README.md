# Entities Module

The Entities module delivers PhoenixKit's dynamic content type system. It allows administrators
to design structured content types with custom fields without writing migrations or code. This README gives a quick orientation for contributors working on the LiveView
layer; the business logic lives in the `PhoenixKit.Modules.Entities` context.

## LiveViews & Components

- `entities.ex` / `.html.heex` – Main dashboard listing entities with table/card views (card view auto-selected on small screens).
- `entity_form.ex` / `.html.heex` – Schema builder for creating and editing entity definitions (with presence locking).
- `entities_settings.ex` / `.html.heex` – Module settings (enable/disable system, defaults).
- `data_navigator.ex` / `.html.heex` – Explorer for entity records with filtering, search, and status management.
- `data_form.ex` / `.html.heex` – Dynamic form renderer for entity entries (with presence locking).
- `hooks.ex` – LiveView hooks (presence, authorization guards, shared assigns).

All templates follow Phoenix 1.8 layout conventions (`<Layouts.app ...>` with `@current_scope`).

## Feature Highlights

- **Entity Designer** – Build custom fields, validations, and display ordering for each entity type.
- **JSONB Storage** – Field definitions stored as JSONB, no database migrations needed for schema changes.
- **Multi-Language Support** – Language tabs in forms, override-only storage for secondary languages, lazy re-keying on primary language change. Driven globally by the Languages module.
- **Data Navigator** – Browse, search, and filter entity data with status filters and archive/restore workflow.
- **Collaborative Editing** – Presence helpers in entity_form and data_form prevent overwrites when multiple admins edit the same record.
- **Settings Guardrails** – Module can be toggled on/off via PhoenixKit Settings (`entities_enabled`).
- **Event Broadcasting** – Hooks integrate with `PhoenixKit.Modules.Entities.Events` for lifecycle tracking.

## Integration Points

- Context modules: `PhoenixKit.Modules.Entities`, `PhoenixKit.Modules.Entities.EntityData`, `PhoenixKit.Modules.Entities.FieldTypes`.
- Multilang module: `PhoenixKit.Modules.Entities.Multilang` – pure-function helpers for multilang JSONB.
- Supporting modules: `PhoenixKit.Modules.Entities.Events`, `PhoenixKit.Modules.Entities.PresenceHelpers`.
- Languages integration: multilang is auto-enabled when `PhoenixKit.Modules.Languages` has 2+ enabled languages.
- Enabling flag: `PhoenixKit.Settings.get_setting("entities_enabled", "false")`.
- Router: available under `{prefix}/admin/entities/*` via `phoenix_kit_routes()`.

## Additional Reading

- Overview: `OVERVIEW.md` (in this directory)
- Deep dive: `DEEP_DIVE.md` (in this directory)
- Languages module: `lib/modules/languages/README.md`

Keep this README in sync whenever new submodules or major workflows are added to the Entities
LiveView stack.
